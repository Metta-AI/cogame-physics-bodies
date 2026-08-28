## The decision layer: the per-turn loop that asks both bugs what they do next,
## and ALWAYS has an answer.
##
## Cadence: one turn every `turnTicks` (36 ticks = 1.5 s of sim time), 60 turns
## per full-length episode. At each turn the server builds BOTH seats' request
## bodies and issues them as ONE PARALLEL BATCH — the ring is a
## simultaneous-decision game, so querying seats one after another would double
## the wall clock for no gain.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets `attempt1Ms`,
## the single retry gets `retryMs`, the inter-batch floor is a bounded sleep, and
## the whole turn is wrapped in a monotonic `turnBudgetMs` deadline — each
## attempt's own deadline is clamped to what is left of it, so the turn cannot be
## overrun by an attempt that started just inside the budget. A provider
## throttle with no other candidate model skips the retry outright (it cannot
## land). On a second failure the seat plays the `pusher` intent for that turn
## and a `fallback` record names the cause. No failure mode leaves a bug
## uncommanded: the controller always has an intent — this turn's, else last
## turn's, else `pusher`'s. There is no sampling loop, no unbounded search and no
## retry-until-success anywhere.

import std/[monotimes, os, strutils, times]
import curly
import sim, intents, control, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `pusher`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    intents*: seq[BugIntent]
    haveIntent*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState()
  result.seats = newSeq[SeatPolicy](BodyCount)
  result.intents = newSeq[BugIntent](BodyCount)
  result.haveIntent = newSeq[bool](BodyCount)
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blPusher
    result.seats[i].label = "pusher"
    result.intents[i] = defaultIntent()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

proc viewFor*(engine: DecisionEngine, sim: SimServer, seat: int): SeatView =
  seatView(sim, seat,
    (if seat < engine.haveIntent.len: engine.haveIntent[seat] else: false),
    (if seat < engine.intents.len: engine.intents[seat] else: defaultIntent()))

proc scriptedFor*(engine: DecisionEngine, sim: SimServer, seat: int,
                  kind: Baseline): BugIntent =
  scriptedIntent(engine.ctl.params, engine.viewFor(sim, seat), kind)

proc pusherFor*(engine: DecisionEngine, sim: SimServer, seat: int): BugIntent =
  ## The published `pusher` intent: the per-turn fallback and the default for a
  ## seat that registers with neither env var.
  pusherIntent(engine.ctl.params, engine.viewFor(sim, seat))

proc installIntent*(engine: var DecisionEngine, seat: int,
                    intent: BugIntent) =
  if seat < 0 or seat >= engine.intents.len:
    return
  engine.intents[seat] = intent
  engine.haveIntent[seat] = true

proc intentForBody*(engine: DecisionEngine, sim: SimServer,
                    bodyIndex: int): BugIntent =
  ## The standing intent driving one bug. A bug whose seat never connected —
  ## or whose seat dropped — is driven by `pusher`, so NO failure mode leaves a
  ## bug uncommanded.
  let seat = sim.seatOfBody(bodyIndex)
  if seat >= 0 and seat < engine.intents.len and engine.haveIntent[seat]:
    return engine.intents[seat]
  var view = seatView(sim, max(0, seat), false, defaultIntent())
  view.body = bodyIndex
  view.foeBody = 1 - bodyIndex
  view.me = sim.bodies[bodyIndex]
  view.foe = sim.bodies[1 - bodyIndex]
  pusherIntent(engine.ctl.params, view)

proc turn*(engine: var DecisionEngine, sim: SimServer, turnIndex: int,
           elapsedSeconds: int): seq[string] =
  ## Runs ONE decision turn and installs each seat's intent. Returns the replay
  ## chat records this turn produced. NEVER raises: every failure path ends in
  ## a legal intent.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
    seats = sim.seatCount()
  ## Throttle state is PER TURN: a daily-token 429 on turn k says nothing about
  ## turn k+1 (the sidecar's window may have rolled), so the flag is cleared
  ## here and only suppresses this turn's retry.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun ----------------------
  # If two more full turns (batch spacing included) would not fit inside the
  # engine's own wall-clock stop, switch the LLM off for the rest of the
  # episode and finish on the scripted layer (microseconds per turn), so the
  # episode ends complete/* instead of deadline.
  if not engine.llmOff:
    let turnSeconds =
      (sim.config.turnSpacingMs + sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "physics-bodies: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? -------------------------------------------
  var open: seq[int]
  for seat in 0 ..< seats:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      ## scripted policy, and `fallback.cause` names both reasons it happens.
      ## Recording it is what makes the two countable: without this an LLM seat
      ## with no key reported llmTurns 0 AND fallbackTurns 0.
      var intent = engine.pusherFor(sim, seat)
      intent.source = isFallback
      engine.installIntent(seat, intent)
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing pusher"))
      echo "physics-bodies llm: seat ", seat,
        " falling back to pusher (", cause, ") on turn ", turnIndex
    else:
      var intent = engine.scriptedFor(sim, seat, engine.seats[seat].baseline)
      intent.source = isScripted
      engine.installIntent(seat, intent)

  # --- the rate floor ------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE, and two seats at a
  # fast turn sit right on it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at 20 req/min with a 50 %
  # margin. The cert fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches -----------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    ## THE PER-TURN BUDGET IS THE OUTER BOUND, not just a pre-check. An attempt
    ## that starts a millisecond inside the budget used to be allowed its whole
    ## `retryMs`, so a turn's worst case was
    ## `turnSpacingMs + attempt1Ms + retryMs` (~20 s) rather than the
    ## `turnBudgetMs` the design wraps the turn in (r1 review N17). Each
    ## attempt's deadline is now clamped to what is LEFT of the budget, floored
    ## at 1 000 ms because curl's CURLOPT_TIMEOUT granularity is whole seconds
    ## and floors — so a turn can overshoot by at most that floor.
    let
      spentMs = (getMonoTime() - turnStart).inMilliseconds.int
      remainingMs = max(0, sim.config.turnBudgetMs - spentMs)
      configuredMs =
        if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
      deadlineMs = max(1000, min(configuredMs, remainingMs))
    var batch: RequestBatch
    for seat in open:
      var user = seatViewJson(engine.viewFor(sim, seat))
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    ## SECONDS and whose conversion FLOORS; sim_config rejects a sub-second
    ## value, so this division is an identity (9000 -> 9 s, 5000 -> 5 s, and
    ## 9 + 5 = 14 s inside the 16 s turnBudgetMs cap).
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var intent = parseIntentReply(text, engine.intents[seat],
          engine.haveIntent[seat])
        intent.source = isLlm
        intent.latencyMs = latency
        engine.installIntent(seat, intent)
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is. Reporting a 429 as
          ## `parse_error` is what made a hosted log unreadable.
          cause = "throttled"
        result.add(fallbackRecord(turnIndex, seat, attempt + 1, cause,
          error.msg))
        echo "physics-bodies llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      ## FAIL FAST. The only model left answered 429, so the retry batch would
      ## be refused the same way: spend the rest of the turn on the scripted
      ## layer instead of on a call that cannot land.
      echo "physics-bodies llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays pusher for this turn ----------------------
  for seat in open:
    var intent = engine.pusherFor(sim, seat)
    intent.source = isFallback
    engine.installIntent(seat, intent)
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the pusher intent"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "physics-bodies llm: seat ", seat, " falling back to pusher (",
      cause, ") on turn ", turnIndex
