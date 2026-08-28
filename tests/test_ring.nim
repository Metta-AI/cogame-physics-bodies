## 3. Ring geometry and rounds.

import std/[random, strformat]
import bodies/[sim, intents, control, baselines]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

let cfg = defaultMatchConfig()

# --- the shrink law, at every tick of a round -----------------------------
block:
  for roundTick in 0 .. cfg.roundTicks:
    let
      got = ringRadiusAt(cfg, int32(roundTick))
      elapsed = max(0, roundTick - cfg.shrinkStartTick)
      want = max(int32(cfg.ringRadiusMinUm),
        int32(int64(cfg.ringRadiusUm) -
          int64(elapsed) * int64(cfg.ringShrinkPerTickUm)))
    check got == want,
      &"shrink law at roundTick {roundTick}: got {got}, want {want}"
  ## The radius at the round clock is exactly 1 992 000 um.
  check ringRadiusAt(cfg, int32(cfg.roundTicks)) == 1_992_000'i32,
    &"the radius at the round clock is " &
    $ringRadiusAt(cfg, int32(cfg.roundTicks)) & ", want 1992000"
  ## And it is a PURE function of the round tick: the round INDEX cannot enter
  ## it, so the law re-derives identically in the browser.
  for roundTick in [0, 143, 144, 200, 396]:
    let first = ringRadiusAt(cfg, int32(roundTick))
    for _ in 0 .. 3:
      check ringRadiusAt(cfg, int32(roundTick)) == first,
        "the shrink law is not a pure function of the round tick"

# --- the seeded start axis, and the END SWAP -----------------------------
block:
  var swapped = 0
  for seed in 1 .. 50:
    var probe = defaultMatchConfig(seed)
    let sim = initSimServer(probe)
    for roundIndex in 0 ..< MaxRoundsDefault:
      let
        a = startPlacement(sim.startAxis[roundIndex], int32(roundIndex), 0)
        b = startPlacement(sim.startAxis[roundIndex], int32(roundIndex), 1)
      ## Both at StartRadius from the centre.
      for place in [a, b]:
        let d = distUm(place.x, place.y, RingCentreX, RingCentreY)
        check abs(int(d) - int(StartRadius)) <= 2_000,
          &"seed {seed} round {roundIndex}: start radius {d} != StartRadius"
      ## 2 x StartRadius apart.
      let apart = distUm(a.x, a.y, b.x, b.y)
      check abs(int(apart) - 2 * int(StartRadius)) <= 4_000,
        &"seed {seed} round {roundIndex}: the bugs start {apart} apart"
      ## Facing each other: each heading points at the ring centre, which for
      ## two diametrically opposite bugs IS the other bug.
      let
        headA = dirIndex(a.hMilli div 1000)
        headB = dirIndex(b.hMilli div 1000)
      check dirIndex(headA + 16) == headB,
        &"seed {seed} round {roundIndex}: the bugs are not facing each other"
      ## The END SWAP: round 1 puts bug 0 at the other end of the same axis.
      if roundIndex + 1 < MaxRoundsDefault:
        let next = startPlacement(sim.startAxis[roundIndex],
          int32(roundIndex + 1), 0)
        if next.x != a.x or next.y != a.y:
          inc swapped
  check swapped >= 50 * (MaxRoundsDefault - 1),
    &"the end swap did not fire on every odd round ({swapped} of " &
    $(50 * (MaxRoundsDefault - 1)) & ")"

# --- the grounded boundary is <=, exactly -------------------------------
block:
  var b = Body()
  b.px = RingCentreX
  b.py = RingCentreY
  b.hMilli = 0
  b.lastCmd = encodeCommand(0, int32(ord(postureEven)), 0)
  ## Put the bug so leg 0's foot sits EXACTLY on the rim.
  let reach = reachForPosture(int32(ord(postureEven)))
  b.px = RingCentreX + RingRadius0 - reach
  b.refreshLegs(RingCentreX, RingCentreY, RingRadius0)
  check b.footGrounded[0], "a foot exactly on the rim is not grounded (want <=)"
  ## One micrometre further and it is not.
  b.px += 1
  b.refreshLegs(RingCentreX, RingCentreY, RingRadius0)
  check not b.footGrounded[0],
    "a foot 1 um beyond the rim is still grounded"

# --- the ring-out predicate fires on the exact tick --------------------
block:
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  ## Bug 0 one micrometre inside, motionless; bug 1 safely in the middle.
  sim.bodies[0].px = RingCentreX + sim.ringRadiusNow
  sim.bodies[0].py = RingCentreY
  sim.bodies[0].vx = 0
  sim.bodies[0].vy = 0
  check not sim.bodies[0].outsideRing(sim.ringRadiusNow),
    "a bug exactly on the rim reads as outside (want >)"
  sim.bodies[0].px += 1
  check sim.bodies[0].outsideRing(sim.ringRadiusNow),
    "a bug 1 um past the rim does not read as outside"

# --- both-outside and the CentreTieUm draw ----------------------------
block:
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  sim.bodies[0].vx = 0
  sim.bodies[0].vy = 0
  sim.bodies[1].vx = 0
  sim.bodies[1].vy = 0
  sim.bodies[0].lastCmd = 0
  sim.bodies[1].lastCmd = 0
  ## Both outside, one clearly farther: the FARTHER one loses.
  sim.bodies[0].px = RingCentreX + sim.ringRadiusNow + 200_000
  sim.bodies[0].py = RingCentreY
  sim.bodies[1].px = RingCentreX - sim.ringRadiusNow - 50_000
  sim.bodies[1].py = RingCentreY
  var cmds = newSeq[uint8](BodyCount)
  sim.step(cmds)
  check sim.roundLog.len == 1, "the both-outside branch did not end the round"
  if sim.roundLog.len == 1:
    check sim.roundLog[0].winner == 1'i32,
      "the FARTHER bug did not lose the both-outside round"
    check sim.roundLog[0].reason == roundRingOut,
      &"the both-outside round ended {sim.roundLog[0].reason}, want ring_out"

block:
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  for i in 0 ..< BodyCount:
    sim.bodies[i].vx = 0
    sim.bodies[i].vy = 0
    sim.bodies[i].lastCmd = 0
  ## Both outside, within CentreTieUm: a DRAW.
  sim.bodies[0].px = RingCentreX + sim.ringRadiusNow + 100_000
  sim.bodies[0].py = RingCentreY
  sim.bodies[1].px = RingCentreX - sim.ringRadiusNow - 100_000 - 5_000
  sim.bodies[1].py = RingCentreY
  var cmds = newSeq[uint8](BodyCount)
  sim.step(cmds)
  check sim.roundLog.len == 1, "the tie branch did not end the round"
  if sim.roundLog.len == 1:
    check sim.roundLog[0].winner == -1'i32 and
      sim.roundLog[0].reason == roundDraw,
      &"a within-CentreTieUm double ring-out banked " &
      $sim.roundLog[0].reason & " to " & $sim.roundLog[0].winner
    check sim.roundsWon == [0'i32, 0'i32], "a draw banked a round win"

# --- the round-clock tiebreak, all three branches --------------------
block:
  ## (a) fewer knockdowns suffered wins.
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  sim.roundTick = int32(cfg.roundTicks - 1)
  for i in 0 ..< BodyCount:
    sim.bodies[i].px = RingCentreX
    sim.bodies[i].py = RingCentreY + int32(400_000 * i)
    sim.bodies[i].vx = 0
    sim.bodies[i].vy = 0
    sim.bodies[i].lastCmd = 0
  sim.bodies[0].knockdowns = 1
  sim.bodies[1].knockdowns = 0
  var cmds = newSeq[uint8](BodyCount)
  sim.step(cmds)
  check sim.roundLog.len == 1 and sim.roundLog[0].winner == 1'i32 and
    sim.roundLog[0].reason == roundDecision,
    "the knockdown tiebreak did not pick the bug with fewer falls"

block:
  ## (b) level knockdowns: the bug CLOSER TO THE CENTRE wins.
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  sim.roundTick = int32(cfg.roundTicks - 1)
  for i in 0 ..< BodyCount:
    sim.bodies[i].vx = 0
    sim.bodies[i].vy = 0
    sim.bodies[i].lastCmd = 0
    sim.bodies[i].knockdowns = 0
  sim.bodies[0].px = RingCentreX + 200_000
  sim.bodies[0].py = RingCentreY
  sim.bodies[1].px = RingCentreX + 1_200_000
  sim.bodies[1].py = RingCentreY
  var cmds = newSeq[uint8](BodyCount)
  sim.step(cmds)
  check sim.roundLog.len == 1 and sim.roundLog[0].winner == 0'i32 and
    sim.roundLog[0].reason == roundDecision,
    "the centre-distance tiebreak did not pick the closer bug"

block:
  ## (c) both within CentreTieUm of the same distance: a DRAW.
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  sim.roundTick = int32(cfg.roundTicks - 1)
  for i in 0 ..< BodyCount:
    sim.bodies[i].vx = 0
    sim.bodies[i].vy = 0
    sim.bodies[i].lastCmd = 0
    sim.bodies[i].knockdowns = 0
  sim.bodies[0].px = RingCentreX + 600_000
  sim.bodies[0].py = RingCentreY
  sim.bodies[1].px = RingCentreX - 600_000 - 5_000
  sim.bodies[1].py = RingCentreY
  var cmds = newSeq[uint8](BodyCount)
  sim.step(cmds)
  check sim.roundLog.len == 1 and sim.roundLog[0].winner == -1'i32 and
    sim.roundLog[0].reason == roundDraw,
    "a level round clock did not draw within CentreTieUm"

# --- the knockout branch -----------------------------------------------
block:
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  for i in 0 ..< BodyCount:
    sim.bodies[i].px = RingCentreX + int32(300_000 * i)
    sim.bodies[i].py = RingCentreY
    sim.bodies[i].vx = 0
    sim.bodies[i].vy = 0
    sim.bodies[i].lastCmd = 0
  sim.bodies[1].knockdowns = int32(cfg.knockdownsToLose)
  var cmds = newSeq[uint8](BodyCount)
  sim.step(cmds)
  check sim.roundLog.len == 1 and sim.roundLog[0].winner == 0'i32 and
    sim.roundLog[0].reason == roundKnockout,
    "three knockdowns did not lose the round by knockout"

if failures > 0:
  quit("test_ring: " & $failures & " failure(s)", 1)
echo "test_ring: ok"
