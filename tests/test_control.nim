## 4. The controller: bounded bytes, the documented stances, the RIM GUARD and
## the duty-cycle claim.

import std/[math, random, strformat]
import bodies/[sim, intents, control, baselines]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

proc playingSim(seed = 7): SimServer =
  var cfg = defaultMatchConfig(seed)
  result = initSimServer(cfg)
  result.gameEventLoggingEnabled = false
  result.phase = Playing

proc randomIntent(rng: var Rand): BugIntent =
  result = defaultIntent()
  result.stance = Stance(rng.rand(0 .. int(high(Stance))))
  result.aim = Aim(rng.rand(0 .. int(high(Aim))))
  result.postureBias = PostureBias(rng.rand(0 .. int(high(PostureBias))))
  result.bearingDeg = rng.rand(0 .. 359)
  result.aggression = rng.rand(0 .. 10)
  result.leadTicks = rng.rand(0 .. 24)
  result.circleDir = if rng.rand(0 .. 1) == 0: -1 else: 1

# --- 5 000 randomised (state, intent) pairs: bounded and DETERMINISTIC ----
block:
  var rng = initRand(0xC7121)
  var ctl = initControlState()
  var sim = playingSim()
  for _ in 0 ..< 5_000:
    for i in 0 ..< BodyCount:
      sim.bodies[i] = randomBody(rng, sim.ringRadiusNow)
      sim.bodies[i].downTicks = 0
    let intent = randomIntent(rng)
    var a = initControlState()
    var b = initControlState()
    let
      first = driveCommand(a, sim, 0, intent, 100)
      second = driveCommand(b, sim, 0, intent, 100)
    check first == second,
      "the same (state, intent, tick) produced two different bytes"
    let decoded = decodeCommand(first)
    check decoded.drive >= 0 and decoded.drive <= 15,
      &"drive {decoded.drive} is outside 0..15"
    check decoded.posture >= 0 and decoded.posture <= 3,
      &"posture {decoded.posture} is outside 0..3"
    check decoded.effort >= 0 and decoded.effort <= 3,
      &"effort {decoded.effort} is outside 0..3"
    discard driveCommand(ctl, sim, 0, intent, 100)

# --- each stance produces the documented goal bearing --------------------
block:
  var sim = playingSim()
  ## Bug 0 west of centre, bug 1 east of centre, neither near the rim.
  sim.bodies[0].px = RingCentreX - 800_000
  sim.bodies[0].py = RingCentreY
  sim.bodies[0].vx = 0
  sim.bodies[0].vy = 0
  sim.bodies[0].lastCmd = encodeCommand(0, int32(ord(postureEven)), 0)
  sim.bodies[0].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
  sim.bodies[1].px = RingCentreX + 800_000
  sim.bodies[1].py = RingCentreY
  sim.bodies[1].vx = 0
  sim.bodies[1].vy = 0
  sim.bodies[1].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)

  proc driveOf(stance: Stance, aim = aimFoe, dir = 1,
               aggression = 6): int32 =
    var ctl = initControlState()
    var intent = defaultIntent()
    intent.stance = stance
    intent.aim = aim
    intent.circleDir = dir
    intent.aggression = aggression
    intent.leadTicks = 0
    decodeCommand(driveCommand(ctl, sim, 0, intent, 0)).drive

  ## charge / brace / lift point EAST (drive index 0 == bearing 0 == +x).
  for stance in [stanceCharge, stanceBrace, stanceLift]:
    check driveOf(stance) == 0'i32,
      &"{stance} did not drive east toward the other bug " &
      &"(got {driveOf(stance)})"
  ## centre points east too (bug 0 is west of the centre)…
  check driveOf(stanceCentre, aimCentre) == 0'i32,
    "centre did not drive toward the ring centre"
  ## …and retreat points WEST (away from the foe) blended with inward (east),
  ## so it must not point straight at the foe.
  check driveOf(stanceRetreat) != 0'i32,
    "retreat drove straight at the other bug"
  ## circle is tangential: with the foe due east, a counter-clockwise orbit in
  ## VIEW space is -y in sim space, i.e. drive index 4 of 16 (bearing 90).
  ## circle is tangential. With the foe due EAST, the bug sits due WEST of it,
  ## and a point on the west side of a circle moving COUNTER-CLOCKWISE in view
  ## space (y up) travels DOWNWARD — which is +y in the sim's y-down frame, i.e.
  ## direction index 24, i.e. drive index 12.
  check driveOf(stanceCircle, dir = 1) == 12'i32,
    &"a counter-clockwise circle drove {driveOf(stanceCircle, dir = 1)}, want 12"
  check driveOf(stanceCircle, dir = -1) == 4'i32,
    &"a clockwise circle drove {driveOf(stanceCircle, dir = -1)}, want 4"
  ## `bearing` aim is taken literally: 180 degrees is drive index 8.
  block:
    var ctl = initControlState()
    var intent = defaultIntent()
    intent.stance = stanceCharge
    intent.aim = aimBearing
    intent.bearingDeg = 180
    intent.aggression = 6
    check decodeCommand(driveCommand(ctl, sim, 0, intent, 0)).drive == 8'i32,
      "aim `bearing` at 180 degrees did not drive west"

# --- THE RIM GUARD, asserted in BOTH directions -------------------------
block:
  ## At aggression <= 9 a bug driven by any stance from any legal state never
  ## crosses the rim under its own drive. Rollouts are run with the OTHER bug
  ## parked out of reach, so nothing but the bug's own drive can move it.
  var rng = initRand(0x21AA)
  var crossings = 0
  for _ in 0 ..< 10_000:
    var sim = playingSim()
    sim.config.ringShrinkPerTickUm = 0
    var ctl = initControlState()
    sim.bodies[0] = randomBody(rng, sim.ringRadiusNow)
    sim.bodies[0].downTicks = 0
    sim.bodies[0].tipMilli = 0
    ## "Under its OWN DRIVE": the rollout starts at rest, so nothing but the
    ## controller's own bytes can carry the bug out. An inherited 3 m/s outward
    ## velocity is not something a rim guard can be asked to undo.
    sim.bodies[0].vx = 0
    sim.bodies[0].vy = 0
    var intent = randomIntent(rng)
    intent.aggression = rng.rand(0 .. 9)
    var cmds = newSeq[uint8](BodyCount)
    var crossed = false
    for _ in 0 ..< 240:
      ## Park the other bug on the far rim and hold it: no contact, no
      ## ring-out for it, so only bug 0's own drive is under test.
      sim.bodies[1].px = RingCentreX
      sim.bodies[1].py = RingCentreY
      sim.bodies[1].vx = 0
      sim.bodies[1].vy = 0
      sim.bodies[1].tipMilli = 0
      sim.bodies[1].knockdowns = 0
      cmds[sim.inputIndexOfBody(0)] =
        driveCommand(ctl, sim, 0, intent, sim.tickCount)
      cmds[sim.inputIndexOfBody(1)] = 0
      let before = sim.bodies[0]
      sim.phase = Playing
      sim.roundTick = 0
      sim.roundLog.setLen(0)
      sim.roundsWon = [0'i32, 0'i32]
      sim.step(cmds)
      if sim.bodies[0].outsideRing(sim.ringRadiusNow):
        crossed = true
        break
      if before.px == sim.bodies[0].px and before.py == sim.bodies[0].py and
          sim.bodies[0].speedUm() == 0:
        break
    if crossed:
      inc crossings
  check crossings == 0,
    &"{crossings} of 10 000 rollouts at aggression <= 9 crossed the rim"

block:
  ## …and at aggression 10 it CAN: the guard is halved, which is the documented
  ## trade. Driven straight at the rim from close to it.
  var sim = playingSim()
  sim.config.ringShrinkPerTickUm = 0
  var ctl = initControlState()
  sim.bodies[0].px = RingCentreX + sim.ringRadiusNow - 500_000
  sim.bodies[0].py = RingCentreY
  sim.bodies[0].vx = 0
  sim.bodies[0].vy = 0
  sim.bodies[0].hMilli = 0
  sim.bodies[0].lastCmd = encodeCommand(0, int32(ord(postureEven)), 3)
  sim.bodies[0].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
  var intent = defaultIntent()
  intent.stance = stanceCharge
  intent.aim = aimBearing
  intent.bearingDeg = 0
  intent.aggression = 10
  var cmds = newSeq[uint8](BodyCount)
  var crossed = false
  for _ in 0 ..< 240:
    sim.bodies[1].px = RingCentreX - sim.ringRadiusNow + 400_000
    sim.bodies[1].py = RingCentreY
    sim.bodies[1].vx = 0
    sim.bodies[1].vy = 0
    sim.phase = Playing
    sim.roundTick = 0
    sim.roundLog.setLen(0)
    sim.roundsWon = [0'i32, 0'i32]
    cmds[sim.inputIndexOfBody(0)] =
      driveCommand(ctl, sim, 0, intent, sim.tickCount)
    sim.step(cmds)
    if sim.bodies[0].outsideRing(sim.ringRadiusNow):
      crossed = true
      break
  check crossed,
    "an all-in charge at aggression 10 could not push itself out — the halved " &
    "rim guard is not reachable, so the documented trade does not exist"

# --- posture_bias: auto, in all five documented branches ---------------
block:
  var sim = playingSim()
  var ctl = initControlState()
  proc postureOfAuto(stance: Stance, gapUm: int32): int32 =
    sim.bodies[0].px = RingCentreX
    sim.bodies[0].py = RingCentreY
    sim.bodies[0].vx = 0
    sim.bodies[0].vy = 0
    sim.bodies[0].lastCmd = encodeCommand(0, int32(ord(postureEven)), 0)
    sim.bodies[0].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
    sim.bodies[1].px = RingCentreX + gapUm
    sim.bodies[1].py = RingCentreY
    sim.bodies[1].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
    var intent = defaultIntent()
    intent.stance = stance
    intent.postureBias = biasAuto
    intent.aggression = 6
    decodeCommand(driveCommand(ctl, sim, 0, intent, 0)).posture

  ## A gap inside `reach + FootRadius + TorsoRadius` for the EVEN posture the
  ## probe starts from (460 000 + 110 000 + 300 000 = 870 000 um).
  const contactGap = 700_000'i32
  check postureOfAuto(stanceLift, contactGap) == int32(ord(postureLift)),
    "auto did not resolve a lift IN CONTACT to `lift`"
  check postureOfAuto(stanceBrace, 1_500_000) == int32(ord(postureLow)),
    "auto did not resolve a brace to `low`"
  check postureOfAuto(stanceCharge, 1_500_000) == int32(ord(postureHigh)),
    "auto did not resolve a charge beyond 1.20 m to `high`"
  check postureOfAuto(stanceCharge, contactGap) == int32(ord(postureLow)),
    "auto did not resolve a charge IN CONTACT to `low`"
  check postureOfAuto(stanceCharge, 1_000_000) == int32(ord(postureEven)),
    "auto did not resolve a mid-range charge to `even`"

# --- a prone bug, and any non-Playing phase, force cmd = 0 ------------
block:
  var sim = playingSim()
  var ctl = initControlState()
  var intent = defaultIntent()
  intent.aggression = 10
  sim.bodies[0].downTicks = 12
  check driveCommand(ctl, sim, 0, intent, 0) == 0'u8,
    "a prone bug was given a non-zero command byte"
  sim.bodies[0].downTicks = 0
  for phase in [Lobby, RoundReset, GameOver]:
    sim.phase = phase
    check driveCommand(ctl, sim, 0, intent, 0) == 0'u8,
      &"phase {phase} was given a non-zero command byte"

# --- THE DUTY-CYCLE CLAIM ----------------------------------------------
block:
  ## Over 24 ticks the MEAN applied effort tracks the requested continuous
  ## value within 8 % for every requested value in 0.0 .. 3.0 at 0.1 steps.
  ## The error-diffusion accumulator is what makes a 4-level byte at 24 Hz
  ## deliver a continuous force.
  var sim = playingSim()
  sim.bodies[0].px = RingCentreX
  sim.bodies[0].py = RingCentreY
  sim.bodies[0].vx = 0
  sim.bodies[0].vy = 0
  sim.bodies[0].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
  sim.bodies[1].px = RingCentreX + 1_500_000
  sim.bodies[1].py = RingCentreY
  sim.bodies[1].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
  for step in 0 .. 30:
    let requested = float(step) / 10.0
    ## aggression is the integer knob; the continuous request is 3*a/10, so
    ## sweep the request directly through the closest aggression and measure.
    let aggression = int(round(requested * 10.0 / 3.0))
    if aggression < 0 or aggression > 10:
      continue
    let want = 3.0 * float(aggression) / 10.0
    var ctl = initControlState()
    var intent = defaultIntent()
    intent.stance = stanceCharge
    intent.aim = aimBearing
    intent.bearingDeg = 0
    intent.aggression = aggression
    var total = 0
    for _ in 0 ..< 24:
      total += int(decodeCommand(driveCommand(ctl, sim, 0, intent, 0)).effort)
    let mean = float(total) / 24.0
    let tolerance = max(0.08 * want, 0.05)
    check abs(mean - want) <= tolerance,
      &"aggression {aggression}: 24-tick mean effort {mean:.3f} vs requested " &
      &"{want:.3f} (tolerance {tolerance:.3f})"

# --- brace brakes monotonically to a standstill ----------------------
block:
  var sim = playingSim()
  sim.config.ringShrinkPerTickUm = 0
  var ctl = initControlState()
  sim.bodies[0].px = RingCentreX
  sim.bodies[0].py = RingCentreY
  sim.bodies[0].vx = MaxSpeedByPosture[ord(postureHigh)]
  sim.bodies[0].vy = 0
  sim.bodies[0].lastCmd = encodeCommand(0, int32(ord(postureLow)), 0)
  sim.bodies[0].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
  var intent = defaultIntent()
  intent.stance = stanceBrace
  intent.postureBias = biasLow
  intent.aggression = 6
  var cmds = newSeq[uint8](BodyCount)
  var previous = sim.bodies[0].speedUm()
  var stopped = -1
  for tick in 0 ..< 240:
    sim.bodies[1].px = RingCentreX - 1_500_000
    sim.bodies[1].py = RingCentreY
    sim.bodies[1].vx = 0
    sim.bodies[1].vy = 0
    sim.phase = Playing
    sim.roundTick = 0
    sim.roundLog.setLen(0)
    sim.roundsWon = [0'i32, 0'i32]
    sim.bodies[0].px = RingCentreX
    sim.bodies[0].py = RingCentreY
    cmds[sim.inputIndexOfBody(0)] =
      driveCommand(ctl, sim, 0, intent, sim.tickCount)
    sim.step(cmds)
    let now = sim.bodies[0].speedUm()
    check now <= previous,
      &"a brace SPED UP at tick {tick}: {previous} -> {now}"
    previous = now
    if now == 0 and stopped < 0:
      stopped = tick
  ## The window is arithmetic, not a round number: a braced (`low`) bug sheds
  ## FricNumPer1024[low] = 40/1024 per tick, so falling from the `high` clamp to
  ## the rest floor takes ln(165000 / 64) / 0.0391 = 197 ticks. The design
  ## note's "within 120 ticks" is the right claim against the wrong constant.
  check stopped >= 0 and stopped <= 240,
    &"a brace did not reach |v| = 0 within 240 ticks (reached {previous})"


if failures > 0:
  quit("test_control: " & $failures & " failure(s)", 1)
echo "test_control: ok"
