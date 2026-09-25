## The decision layer: the per-turn loop that asks both bugs what they do next,
## and ALWAYS has an answer.
##
## Cadence: one turn every `turnTicks` (36 ticks = 1.5 s of sim time), 60 turns
## per full-length episode. At each turn the server builds BOTH seats' private
## views and sends them in ONE BATCH — the ring is a
## simultaneous-decision game, so querying seats one after another would double
## the wall clock for no gain.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets `attempt1Ms`,
## the single retry gets `retryMs`, the inter-batch floor is a bounded sleep, and
## the whole turn is wrapped in a monotonic `turnBudgetMs` deadline — each
## attempt's own deadline is clamped to what is left of it, so the turn cannot be
## overrun by an attempt that started just inside the budget. A player reported
## throttle skips the retry. On a second failure the seat plays `pusher`
## and a `fallback` record names the cause. No failure mode leaves a bug
## uncommanded: the controller always has an intent — this turn's, else last
## turn's, else `pusher`'s. There is no sampling loop, no unbounded search and no
## retry-until-success anywhere.

import std/[monotimes, os, times]
import sim, intents, control, baselines

type
  BatchCall* = object
    seat*: int
    view*: string
    turn*: int
    retry*: bool

  BatchReply* = object
    ok*: bool
    action*: string
    cause*: string
    error*: string

  BatchFn* = proc(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
    {.closure, gcsafe.}

  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `pusher`.
    isExternal*: bool
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    batch*: BatchFn
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    intents*: seq[BugIntent]
    haveIntent*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    externalOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.ctl = initControlState()
  result.seats = newSeq[SeatPolicy](BodyCount)
  result.intents = newSeq[BugIntent](BodyCount)
  result.haveIntent = newSeq[bool](BodyCount)
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blPusher
    result.seats[i].label = "pusher"
    result.intents[i] = defaultIntent()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isExternal:
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

  # --- budget guard: settle EARLY rather than overrun ----------------------
  # If two more full turns (batch spacing included) would not fit inside the
  # engine's own wall-clock stop, switch external calls off for the rest of the
  # episode and finish on the scripted layer (microseconds per turn), so the
  # episode ends complete/* instead of deadline.
  if not engine.externalOff:
    let turnSeconds =
      (sim.config.turnSpacingMs + sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.externalOff = true
      result.add(budgetGuardRecord(turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "physics-bodies: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? -------------------------------------------
  var open: seq[int]
  for seat in 0 ..< seats:
    if engine.seats[seat].isExternal and not engine.externalOff:
      open.add(seat)
    elif engine.seats[seat].isExternal:
      ## An external seat skipped by the budget guard is a FALLBACK. Record it
      ## so accepted external orders and fallback turns remain countable.
      var intent = engine.pusherFor(sim, seat)
      intent.source = isFallback
      engine.installIntent(seat, intent)
      result.add(fallbackRecord(turnIndex, seat, 1, "budget_guard",
        "the decision budget is exhausted; playing pusher"))
      echo "physics-bodies llm: seat ", seat,
        " falling back to pusher (budget_guard) on turn ", turnIndex
    else:
      var intent = engine.scriptedFor(sim, seat, engine.seats[seat].baseline)
      intent.source = isScripted
      engine.installIntent(seat, intent)

  # --- the rate floor ------------------------------------------------------
  # Hold the start of consecutive player batches `turnSpacingMs` apart. The
  # cert fixture sets it to zero, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches -----------------------------------------
  var attempt = 0
  var lastCause = newSeq[string](seats)
  var failFast: seq[int]
  while open.len > 0 and attempt < 2:
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
    ## at 1 000 ms because the player socket deadline is in whole seconds.
    let
      spentMs = (getMonoTime() - turnStart).inMilliseconds.int
      remainingMs = max(0, sim.config.turnBudgetMs - spentMs)
      configuredMs =
        if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
      deadlineMs = max(1000, min(configuredMs, remainingMs))
    var calls: seq[BatchCall]
    for seat in open:
      calls.add BatchCall(seat: seat,
        view: seatViewJson(engine.viewFor(sim, seat)),
        turn: turnIndex, retry: attempt > 0)
    let started = getMonoTime()
    let replies = engine.batch(calls, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let reply = replies[position]
        if not reply.ok:
          cause = if reply.cause.len > 0: reply.cause else: "transport_error"
          raise newException(ValueError, reply.error)
        var intent = parseIntentReply(reply.action, engine.intents[seat],
          engine.haveIntent[seat])
        intent.source = isLlm
        intent.latencyMs = latency
        engine.installIntent(seat, intent)
      except CatchableError as error:
        result.add(fallbackRecord(turnIndex, seat, attempt + 1, cause,
          error.msg))
        lastCause[seat] = cause
        echo "physics-bodies llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if attempt == 1:
      var retryable: seq[int]
      for seat in open:
        if lastCause[seat] in ["throttled", "no_credentials"]:
          failFast.add(seat)
        else:
          retryable.add(seat)
      open = retryable

  # --- anything still open plays pusher for this turn ----------------------
  open.add(failFast)
  for seat in open:
    var intent = engine.pusherFor(sim, seat)
    intent.source = isFallback
    engine.installIntent(seat, intent)
    let cause = if lastCause[seat].len > 0: lastCause[seat] else: "timeout"
    result.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the pusher intent"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "physics-bodies llm: seat ", seat, " falling back to pusher (",
      cause, ") on turn ", turnIndex
