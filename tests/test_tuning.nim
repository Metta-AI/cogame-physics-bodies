## The tuning pin: the shipped `BaselineParams` defaults must still equal the
## pick recorded by tools/tune_baselines.nim.
##
## A sweep that is never committed drifts silently; a default that is changed by
## hand without re-running the sweep is a claim nobody measured.

import std/[json, strformat]
import bodies/[sim, control]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

let
  recorded = parseJson(readFile(repoFile("tools/ci/baseline_tuning.json")))
  pick = recorded["pick"]
  shipped = defaultBaselineParams()

check pick["rimGuardUm"].getInt() == shipped.rimGuardUm,
  &"rimGuardUm ships {shipped.rimGuardUm} but the sweep picked " &
  $pick["rimGuardUm"].getInt()
check pick["chargeLeadTicks"].getInt() == shipped.chargeLeadTicks,
  &"chargeLeadTicks ships {shipped.chargeLeadTicks} but the sweep picked " &
  $pick["chargeLeadTicks"].getInt()
check pick["liftEngageUm"].getInt() == shipped.liftEngageUm,
  &"liftEngageUm ships {shipped.liftEngageUm} but the sweep picked " &
  $pick["liftEngageUm"].getInt()

## And the sweep's own measurement still clears the bars tests/test_baselines
## asserts, so the recorded pick is a pick and not a coin flip.
let measured = recorded["measured"]
check measured["pusherWins"].getInt() >= 14,
  "the recorded sweep's pick does not beat `anchor` on 14 of 20 seeds"
check measured["faults"].getInt() == 0,
  "the recorded sweep's pick faulted on some seed"
check measured["mirrorKnockdowns"].getInt() > 0,
  "the recorded sweep saw no knockdown in the mirror sweep"
let rounds = measured["rounds"].getInt()
check rounds > 0 and measured["ringOuts"].getInt() * 100 div rounds >= 60,
  "the recorded sweep's ring-out share is under 60 %"
check recorded["grid"].len >= 12,
  "the recorded sweep explored fewer than 12 grid points"

if failures > 0:
  quit("test_tuning: " & $failures & " failure(s)", 1)
echo "test_tuning: ok"
