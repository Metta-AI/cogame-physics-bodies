## Sweeps the THREE `BaselineParams` tunables over a bounded grid and prints the
## pick as JSON, exactly as `tools/ci/baseline_tuning.json` records it.
##
## THE PHYSICS CONSTANTS IN docs/RULES.md ARE NOT SWEPT AND ARE NOT TUNABLE. If
## `pusher` cannot beat `anchor`, or a ring-out stops deciding most rounds, the
## sweep moves these three numbers, not the sim:
##
##   rimGuardUm        how far from the rim the autopilot's guard starts
##   chargeLeadTicks   how far ahead `pusher` leads a distant target
##   liftEngageUm      how close `pusher` has to be before it tries a lift
##
##   nim c -d:release --path:src -r tools/tune_baselines.nim \
##     > tools/ci/baseline_tuning.json
##
## tests/test_tuning.nim asserts the shipped defaults still equal the recorded
## pick, so a sweep that is never committed fails CI rather than drifting.

import std/[json, strformat]
import bodies/[sim, intents, control, baselines]

const
  Seeds = 20
  RimGuards = [400_000, 600_000, 800_000]
  ChargeLeads = [2, 4, 6, 8]
  LiftEngages = [620_000, 820_000, 1_020_000]

type Outcome = object
  pusherWins: int
  rounds: int
  ringOuts: int
  knockdowns: int
  faults: int

proc play(seed: int, params: BaselineParams,
          kinds: array[BodyCount, Baseline]): tuple[
            won: array[BodyCount, int], rounds, ringOuts, knockdowns: int,
            fault: bool] =
  var cfg = defaultGameConfig()
  cfg.seed = seed
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  var ctl = initControlState()
  ctl.params = params
  discard sim.addPlayer("seat-0", 0, "")
  discard sim.addPlayer("seat-1", 1, "")
  var
    cmds = newSeq[uint8](BodyCount)
    lastIntent: array[BodyCount, BugIntent]
    haveIntent: array[BodyCount, bool]
    lastTurn = -1
  for i in 0 ..< BodyCount:
    lastIntent[i] = defaultIntent()
  try:
    while sim.phase != GameOver and sim.tickCount < 4000:
      if sim.phase == Playing:
        let turn = sim.tickCount div cfg.turnTicks
        if sim.tickCount mod cfg.turnTicks == 0 and turn != lastTurn:
          lastTurn = turn
          for seat in 0 ..< sim.seatCount():
            let view = seatView(sim, seat, haveIntent[seat], lastIntent[seat])
            lastIntent[seat] = scriptedIntent(params, view, kinds[seat])
            haveIntent[seat] = true
      for i in 0 ..< BodyCount:
        let seat = sim.seatOfBody(i)
        let intent =
          if seat >= 0 and haveIntent[seat]: lastIntent[seat]
          else: defaultIntent()
        cmds[sim.inputIndexOfBody(i)] =
          driveCommand(ctl, sim, i, intent, sim.tickCount)
      sim.step(cmds)
  except CatchableError:
    result.fault = true
  for i in 0 ..< BodyCount:
    result.won[i] = int(sim.roundsWon[i])
  result.rounds = sim.roundLog.len
  for entry in sim.roundLog:
    if entry.reason == roundRingOut:
      inc result.ringOuts
    result.knockdowns += int(entry.knockdowns[0]) + int(entry.knockdowns[1])

proc evaluate(params: BaselineParams): Outcome =
  for seed in 1 .. Seeds:
    let duel = play(seed, params, [blPusher, blAnchor])
    ## Seat 0 registered as `pusher`; `perm` decides which BODY that is.
    var probe = defaultGameConfig()
    probe.seed = seed
    let pusherBody = int(initSimServer(probe).perm[0])
    if duel.won[pusherBody] > duel.won[1 - pusherBody]:
      inc result.pusherWins
    result.rounds += duel.rounds
    result.ringOuts += duel.ringOuts
    if duel.fault:
      inc result.faults
    let mirror = play(seed, params, [blPusher, blPusher])
    result.knockdowns += mirror.knockdowns
    if mirror.fault:
      inc result.faults

proc score(outcome: Outcome): int =
  ## The pick maximises, in order: no faults, `pusher` beating `anchor`, the
  ## ring-out share (proof the mechanic is reachable and not a curiosity), and
  ## at least one knockdown in the mirror sweep (proof the fall is reachable).
  if outcome.faults > 0:
    return -1_000_000
  let ringOutPct =
    if outcome.rounds > 0: outcome.ringOuts * 100 div outcome.rounds else: 0
  outcome.pusherWins * 1000 + ringOutPct * 10 +
    (if outcome.knockdowns > 0: 5 else: -5000)

when isMainModule:
  var
    best = defaultBaselineParams()
    bestScore = low(int)
    bestOutcome: Outcome
    rows = newJArray()
  for rim in RimGuards:
    for lead in ChargeLeads:
      for lift in LiftEngages:
        let params = BaselineParams(
          rimGuardUm: rim, chargeLeadTicks: lead, liftEngageUm: lift)
        let outcome = evaluate(params)
        let value = score(outcome)
        rows.add %*{
          "rimGuardUm": rim,
          "chargeLeadTicks": lead,
          "liftEngageUm": lift,
          "pusherWins": outcome.pusherWins,
          "rounds": outcome.rounds,
          "ringOuts": outcome.ringOuts,
          "mirrorKnockdowns": outcome.knockdowns,
          "faults": outcome.faults,
          "score": value
        }
        stderr.writeLine(&"rim={rim} lead={lead} lift={lift} " &
          &"wins={outcome.pusherWins}/{Seeds} " &
          &"ringOuts={outcome.ringOuts}/{outcome.rounds} " &
          &"kd={outcome.knockdowns} faults={outcome.faults} score={value}")
        if value > bestScore:
          bestScore = value
          best = params
          bestOutcome = outcome
  echo (%*{
    "seeds": Seeds,
    "pick": {
      "rimGuardUm": best.rimGuardUm,
      "chargeLeadTicks": best.chargeLeadTicks,
      "liftEngageUm": best.liftEngageUm
    },
    "measured": {
      "pusherWins": bestOutcome.pusherWins,
      "rounds": bestOutcome.rounds,
      "ringOuts": bestOutcome.ringOuts,
      "mirrorKnockdowns": bestOutcome.knockdowns,
      "faults": bestOutcome.faults
    },
    "grid": rows
  }).pretty()
