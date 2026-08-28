## 15. Perf (RELEASE-ONLY): 2160 ticks of physics plus 4320 controller
## evaluations, bounded at 60 s.
##
## The target is under 3 s on a CI runner; the bound is 20x that, so this fails
## on an algorithmic regression (an accidental O(n^2) in the contact loop, an
## unbounded allocation per tick) rather than on a noisy runner.

import std/[monotimes, strformat, times]
import bodies/[sim, intents, control, baselines]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

block:
  var cfg = defaultMatchConfig()
  cfg.roundsToClinch = MaxRoundsDefault      ## never clinch: play every tick
  cfg.maxRounds = MaxRoundsDefault
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  var ctl = initControlState()
  for seat in 0 ..< BodyCount:
    discard sim.addPlayer("seat-" & $seat, seat, "")
  var
    cmds = newSeq[uint8](BodyCount)
    lastIntent: array[BodyCount, BugIntent]
    haveIntent: array[BodyCount, bool]
    evaluations = 0
    lastTurn = -1
  for i in 0 ..< BodyCount:
    lastIntent[i] = defaultIntent()
  let started = getMonoTime()
  var ticks = 0
  while ticks < MaxTicksDefault:
    if sim.phase == Playing:
      let turn = sim.tickCount div cfg.turnTicks
      if sim.tickCount mod cfg.turnTicks == 0 and turn != lastTurn:
        lastTurn = turn
        for seat in 0 ..< BodyCount:
          lastIntent[seat] = scriptedIntent(ctl.params,
            seatView(sim, seat, haveIntent[seat], lastIntent[seat]), blPusher)
          haveIntent[seat] = true
    for i in 0 ..< BodyCount:
      let seat = sim.seatOfBody(i)
      cmds[sim.inputIndexOfBody(i)] = driveCommand(ctl, sim, i,
        (if seat >= 0 and haveIntent[seat]: lastIntent[seat]
         else: defaultIntent()), sim.tickCount)
      inc evaluations
    if sim.phase == GameOver:
      sim = initSimServer(cfg)
      sim.gameEventLoggingEnabled = false
      for seat in 0 ..< BodyCount:
        discard sim.addPlayer("seat-" & $seat, seat, "")
      lastTurn = -1
    else:
      sim.step(cmds)
    inc ticks
  let elapsed = (getMonoTime() - started).inMilliseconds
  check evaluations >= 2 * MaxTicksDefault,
    &"only {evaluations} controller evaluations, want >= " &
    $(2 * MaxTicksDefault)
  check elapsed < 60_000,
    &"{ticks} ticks + {evaluations} controller evaluations took {elapsed} ms, " &
    "bound 60 000 ms"
  echo &"test_perf: {ticks} ticks + {evaluations} evaluations in {elapsed} ms"

if failures > 0:
  quit("test_perf: " & $failures & " failure(s)", 1)
echo "test_perf: ok"
