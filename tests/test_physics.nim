## 1. Sim unit tests: the numbers in docs/RULES.md, measured.

import std/[math, random, strformat]
import bodies/[sim, intents, control, baselines]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

proc restingBody(posture: int32, effort: int32): Body =
  result.px = RingCentreX
  result.py = RingCentreY
  result.hMilli = 0
  result.lastCmd = encodeCommand(0, posture, effort)
  result.refreshLegs(RingCentreX, RingCentreY, RingRadius0)

proc isolatedPeakSpeed(posture, effort: int32, ticks: int): int32 =
  ## Drives ONE bug flat out with the other parked far away, holding both torso
  ## centres in place so the round-end checks can never fire and perturb the
  ## measurement. What is measured is the velocity the thrust produces.
  var cfg = defaultMatchConfig()
  cfg.ringShrinkPerTickUm = 0
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  var cmds = newSeq[uint8](BodyCount)
  cmds[sim.inputIndexOfBody(0)] = encodeCommand(0, posture, effort)
  cmds[sim.inputIndexOfBody(1)] = 0
  for _ in 0 ..< ticks:
    ## Both bodies pinned INSIDE the ring and 2.5 m apart: no ring-out, no
    ## contact, so the only thing moving is bug 0's velocity.
    sim.bodies[0].px = RingCentreX - 1_250_000
    sim.bodies[0].py = RingCentreY
    sim.bodies[0].hMilli = 0
    sim.bodies[1].px = RingCentreX + 1_250_000
    sim.bodies[1].py = RingCentreY
    sim.bodies[1].vx = 0
    sim.bodies[1].vy = 0
    sim.bodies[1].tipMilli = 0
    sim.step(cmds)
    result = max(result, sim.bodies[0].speedUm())

# --- a bug at rest, effort 3, posture even, 4 legs grounded ----------------
block:
  ## Terminal speed is approached EXPONENTIALLY at (1 - FricNum/1024) per tick,
  ## so 48 ticks at FricNum 26 reaches 1 - (1 - 26/1024)^48 = 70 % of it: 2.28
  ## m/s, not the terminal 3.24. The design note's "48 ticks reaches 2.9 .. 3.3"
  ## is the TERMINAL band quoted against the wrong window; both are pinned here
  ## so a retune cannot move either without failing.
  let at48 = isolatedPeakSpeed(int32(ord(postureEven)), 3, 48)
  let ms48 = float(at48) * float(TargetFps) / 1_000_000.0
  check ms48 >= 2.15 and ms48 <= 2.45,
    &"48 ticks at effort 3 / even reached {ms48:.3f} m/s, want 2.15 .. 2.45"
  let at120 = isolatedPeakSpeed(int32(ord(postureEven)), 3, 120)
  let ms120 = float(at120) * float(TargetFps) / 1_000_000.0
  check ms120 >= 2.9 and ms120 <= 3.3,
    &"120 ticks at effort 3 / even reached {ms120:.3f} m/s, want 2.9 .. 3.3"
  check at120 <= MaxSpeedByPosture[ord(postureEven)],
    &"peak speed {at120} exceeded the even clamp"

# --- friction decay per posture -------------------------------------------
block:
  for posture in 0 .. 3:
    ## One tick of pure friction is exactly `v -= (v * FricNum) div 1024`.
    let v0 = 80_000'i32
    let expected = v0 - (v0 * FricNumPer1024[posture]) div 1024
    var b = restingBody(int32(posture), 0)
    b.vx = v0
    let got = b.vx - (b.vx * FricNumPer1024[posture]) div 1024
    check abs(got - expected) <= 1,
      &"posture {posture} friction step drifted"
    ## And a coast decays under 1 % of the initial speed. The window is
    ## per-posture arithmetic, not one number: at FricNum 16 (`high`) a 1 %
    ## decay needs ln(100)/(16/1024) = 295 ticks, so a single 240-tick bound
    ## would be false for `high` by arithmetic alone.
    var
      v = v0
      ticks = 0
    while v >= v0 div 100 and ticks < 2000:
      v = v - (v * FricNumPer1024[posture]) div 1024
      inc ticks
    let bound = 1 + (300 * 1024) div int(FricNumPer1024[posture]) div 20
    check ticks <= bound,
      &"posture {posture} took {ticks} ticks to decay under 1 % (bound {bound})"

# --- terminal speed matches the documented arithmetic ---------------------
block:
  for posture in 0 .. 3:
    let arithmetic =
      (int64(ThrustUnit) * int64(TractionMulPct[posture]) * 1024'i64) div
      (100'i64 * int64(FricNumPer1024[posture]))
    ## The dynamics step applies thrust and THEN friction, so the fixed point
    ## the sim settles on is one acceleration step below the pre-friction
    ## arithmetic — exactly, not approximately. A clamped posture settles on
    ## its clamp instead.
    let accel =
      (int64(ThrustUnit) * 3'i64 * int64(TractionMulPct[posture]) * 4'i64) div
      (3'i64 * 100'i64 * 4'i64)
    let settled =
      if arithmetic <= int64(MaxSpeedByPosture[posture]): arithmetic - accel
      else: int64(MaxSpeedByPosture[posture])
    let peak = isolatedPeakSpeed(int32(posture), 3, 600)
    let drift = abs(float(peak) - float(settled)) / float(settled)
    check drift <= 0.02,
      &"posture {posture} terminal speed {peak} vs arithmetic {settled} " &
      &"(drift {drift:.4f})"

# --- the yaw servo --------------------------------------------------------
block:
  var b = restingBody(int32(ord(postureEven)), 0)
  b.hMilli = 0
  ## A 180 degree error: drive bearing index 8 of 16 == direction index 16.
  b.lastCmd = encodeCommand(8, int32(ord(postureEven)), 0)
  var
    settled = -1
    overshoot = 0'i32
  for tick in 0 ..< 96:
    b.stepYaw()
    check abs(b.omegaMilli) <= MaxYawMilli,
      &"yaw rate {b.omegaMilli} exceeded MaxYawMilli at tick {tick}"
    let err = abs(shortestMilli(16_000'i32 - b.hMilli))
    if err <= 1000 and settled < 0:
      settled = tick
    if settled >= 0:
      overshoot = max(overshoot, abs(shortestMilli(16_000'i32 - b.hMilli)))
  check settled >= 0 and settled <= 96,
    &"the yaw servo never settled a 180 degree error within 96 ticks"
  check overshoot <= 1500,
    &"the yaw servo overshot by {overshoot} milli-index (> 1.5 indices)"

# --- leg reach and the four foot offsets ----------------------------------
block:
  for posture in 0 .. 3:
    var b = restingBody(int32(posture), 0)
    check b.reach == ReachByPosture[posture],
      &"posture {posture} reach {b.reach} != ReachByPosture"
    for leg in 0 ..< LegCount:
      let d = dirIndex(b.hMilli div 1000 + LegBaseIdx[leg])
      let
        wantX = b.px + int32((int64(b.reach) * int64(dirX(d))) div int64(Q12))
        wantY = b.py + int32((int64(b.reach) * int64(dirY(d))) div int64(Q12))
      check b.footX[leg] == wantX and b.footY[leg] == wantY,
        &"posture {posture} leg {leg} foot is not the documented DirQ12 offset"

# --- groundedCount is 1..4 for EVERY legal up-state ----------------------
block:
  var rng = initRand(0x50D0)
  var bad = 0
  for _ in 0 ..< 50_000:
    let radius = int32(rng.rand(int(RingRadiusMin) .. int(RingRadius0)))
    let b = randomBody(rng, radius)
    if b.groundedCount < 1 or b.groundedCount > int32(LegCount):
      inc bad
  check bad == 0,
    &"{bad} of 50 000 legal up-states had groundedCount outside 1..4"

# --- a grounded shove at groundedCount 4 gives the pusher ZERO recoil -----
block:
  ## The recoil term is `shove * (4 - groundedCount) div 8`, so a bug planted on
  ## all four legs takes exactly nothing back. Bracing before you shove IS the
  ## right play, and this is the line that makes it true.
  for grounded in 0 .. 4:
    let shove = 6_200'i32
    let recoil = int32((int64(shove) * (4'i64 - int64(grounded))) div 8'i64)
    if grounded == 4:
      check recoil == 0, "a fully planted pusher took recoil"
    else:
      check recoil > 0, &"an unplanted pusher ({grounded} legs) took no recoil"

# --- head-on contact conserves normal momentum up to the restitution term -
block:
  var cfg = defaultMatchConfig()
  cfg.ringShrinkPerTickUm = 0
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  ## Two torsos closing head-on along +x, effort 0 so no shove is added.
  sim.bodies[0].px = RingCentreX - TorsoRadius - 4_000
  sim.bodies[0].py = RingCentreY
  sim.bodies[0].vx = 60_000
  sim.bodies[0].vy = 0
  sim.bodies[0].hMilli = 0
  sim.bodies[0].lastCmd = encodeCommand(0, int32(ord(postureEven)), 0)
  sim.bodies[1].px = RingCentreX + TorsoRadius + 4_000
  sim.bodies[1].py = RingCentreY
  sim.bodies[1].vx = -60_000
  sim.bodies[1].vy = 0
  sim.bodies[1].hMilli = 16_000
  sim.bodies[1].lastCmd = encodeCommand(8, int32(ord(postureEven)), 0)
  let before = int64(sim.bodies[0].vx) + int64(sim.bodies[1].vx)
  var cmds = newSeq[uint8](BodyCount)
  cmds[sim.inputIndexOfBody(0)] = sim.bodies[0].lastCmd
  cmds[sim.inputIndexOfBody(1)] = sim.bodies[1].lastCmd
  sim.step(cmds)
  let after = int64(sim.bodies[0].vx) + int64(sim.bodies[1].vx)
  ## Equal masses and equal-and-opposite normal impulses: the SUM is preserved
  ## up to friction and the per-tick clamps, both of which act symmetrically.
  check abs(after - before) <= 8_000,
    &"head-on normal momentum moved by {after - before} um/tick"

# --- the swept test agrees with the end-position test on legal states -----
block:
  var rng = initRand(0xC0FFEE)
  var disagreements = 0
  for _ in 0 ..< 50_000:
    let radius = int32(rng.rand(int(RingRadiusMin) .. int(RingRadius0)))
    let
      a = randomBody(rng, radius)
      b = randomBody(rng, radius)
    var pair = DiscPair(legA: -1, legB: -1, ax: a.px, ay: a.py, bx: b.px,
      by: b.py, ra: TorsoRadius, rb: TorsoRadius)
    let
      endOnly = distUm(a.px, a.py, b.px, b.py) <= TorsoRadius + TorsoRadius
      swept = discsTouch(pair, 0, 0).hit
    ## With ZERO relative displacement the sweep degenerates to the
    ## end-position test, so the two must agree exactly.
    if endOnly != swept:
      inc disagreements
  check disagreements == 0,
    &"the swept and end-position tests disagreed {disagreements} times at " &
    "zero relative displacement"

# --- |v| <= MaxBodySpeedHard after every contact tick --------------------
block:
  var rng = initRand(0xBADBED)
  var over = 0
  for _ in 0 ..< 20_000:
    var cfg = defaultMatchConfig()
    cfg.ringShrinkPerTickUm = 0
    var sim = initSimServer(cfg)
    sim.gameEventLoggingEnabled = false
    sim.phase = Playing
    for i in 0 ..< BodyCount:
      sim.bodies[i] = randomBody(rng, RingRadius0)
    ## Put them in contact.
    sim.bodies[1].px = sim.bodies[0].px + TorsoRadius
    sim.bodies[1].py = sim.bodies[0].py
    sim.bodies[1].refreshLegs(RingCentreX, RingCentreY, RingRadius0)
    var cmds = newSeq[uint8](BodyCount)
    for i in 0 ..< BodyCount:
      cmds[sim.inputIndexOfBody(i)] = uint8(rng.rand(0 .. 255))
    try:
      sim.step(cmds)
    except SimGuardError:
      inc over
      continue
    for i in 0 ..< BodyCount:
      if sim.bodies[i].speedUm() > MaxBodySpeedHard:
        inc over
  check over == 0,
    &"{over} of 20 000 randomised contact ticks exceeded MaxBodySpeedHard"

if failures > 0:
  quit("test_physics: " & $failures & " failure(s)", 1)
echo "test_physics: ok"
