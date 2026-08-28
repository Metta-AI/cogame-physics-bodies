## 5. The published scripted baselines (RELEASE-ONLY: it plays 60 episodes).
##
## Two things are pinned here. First the BOUNDED-ORDERS / LEGALITY assertion:
## every intent a baseline emits validates against the reply schema, and the
## byte the controller compiles from it is in range. Second the TUNING PIN: if
## the baselines cannot ring each other out, the three `BaselineParams` numbers
## are wrong — re-run tools/tune_baselines.nim and commit the sweep's pick. THE
## PHYSICS CONSTANTS DO NOT MOVE.

import std/[random, strformat, unicode]
import bodies/[sim, intents, control, baselines]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

# --- bounded orders: 500 states x both baselines ------------------------
block:
  var rng = initRand(0xBA5E)
  var ctl = initControlState()
  for _ in 0 ..< 500:
    var cfg = defaultMatchConfig(rng.rand(1 .. 1_000_000))
    var sim = initSimServer(cfg)
    sim.gameEventLoggingEnabled = false
    sim.phase = Playing
    sim.ringRadiusNow = int32(rng.rand(int(RingRadiusMin) ..
      int(RingRadius0)))
    for i in 0 ..< BodyCount:
      sim.bodies[i] = randomBody(rng, sim.ringRadiusNow)
    sim.roundIndex = int32(rng.rand(0 ..< MaxRoundsDefault))
    for kind in [blPusher, blAnchor]:
      for seat in 0 ..< BodyCount:
        let view = seatView(sim, seat, false, defaultIntent())
        let intent = scriptedIntent(ctl.params, view, kind)
        check intent.aggression >= 0 and intent.aggression <= 10,
          &"{kind} emitted aggression {intent.aggression}"
        check intent.bearingDeg >= 0 and intent.bearingDeg <= 359,
          &"{kind} emitted bearing_deg {intent.bearingDeg}"
        check intent.leadTicks >= 0 and intent.leadTicks <= 24,
          &"{kind} emitted lead_ticks {intent.leadTicks}"
        check intent.circleDir == -1 or intent.circleDir == 1,
          &"{kind} emitted circle_dir {intent.circleDir}"
        check intent.note.runeLen <= MaxNoteRunes,
          &"{kind} emitted a {intent.note.runeLen}-rune note"
        check intent.say.runeLen <= MaxSayRunes,
          &"{kind} emitted a {intent.say.runeLen}-rune say"
        check intent.say == sanitizeSay(intent.say),
          &"{kind} emitted an unsanitized say: " & intent.say
        ## The enums are closed by construction (they ARE enums), so what
        ## matters is that the compiled BYTE is in range for every one of them.
        let cmd = driveCommand(ctl, sim, sim.bodyOfSeat(seat).max(0), intent, 0)
        let decoded = decodeCommand(cmd)
        check decoded.drive >= 0 and decoded.drive <= 15 and
          decoded.posture >= 0 and decoded.posture <= 3 and
          decoded.effort >= 0 and decoded.effort <= 3,
          &"{kind} compiled an out-of-range byte {cmd}"

# --- the tuning pin ------------------------------------------------------
block:
  const Seeds = 20
  var
    pusherWins = 0
    rounds = 0
    ringOuts = 0
    faults = 0
  for seed in 1 .. Seeds:
    var cfg = defaultMatchConfig(seed)
    let episode = runEpisode(cfg, [blPusher, blAnchor])
    ## Seat 0 registered as `pusher`; `perm` decides which BODY that is.
    let pusherBody = int(episode.sim.perm[0])
    if episode.sim.roundsWon[pusherBody] >
        episode.sim.roundsWon[1 - pusherBody]:
      inc pusherWins
    rounds += episode.sim.roundLog.len
    for entry in episode.sim.roundLog:
      if entry.reason == roundRingOut:
        inc ringOuts
    if episode.sim.endReason == ReasonFault:
      inc faults
  check pusherWins >= 14,
    &"`pusher` beat `anchor` on only {pusherWins} of {Seeds} seeds (want >= 14)"
  check rounds > 0, "no rounds were played across the sweep"
  let ringOutPct = if rounds > 0: ringOuts * 100 div rounds else: 0
  check ringOutPct >= 60,
    &"a ring-out decided only {ringOutPct} % of {rounds} rounds (want >= 60 %)"
  check faults == 0, &"{faults} of {Seeds} seeds ended in a fault"

# --- the fall mechanic is reachable -------------------------------------
block:
  const Seeds = 20
  var knockdowns = 0
  var faults = 0
  for seed in 1 .. Seeds:
    var cfg = defaultMatchConfig(seed)
    let episode = runEpisode(cfg, [blPusher, blPusher])
    for i in 0 ..< BodyCount:
      knockdowns += int(episode.sim.knockdownsSuffered[i])
    if episode.sim.endReason == ReasonFault:
      inc faults
  check knockdowns > 0,
    "no knockdown occurred across a `pusher` vs `pusher` sweep of 20 seeds — " &
    "the fall mechanic is unreachable"
  check faults == 0, &"{faults} of {Seeds} mirror seeds ended in a fault"

if failures > 0:
  quit("test_baselines: " & $failures & " failure(s)", 1)
echo "test_baselines: ok"
