## The controller: ONE deterministic function, evaluated once per tick per
## body, that compiles a standing tactical intent into the command byte the
## replay records.
##
## Both LLM intents and scripted-baseline intents go through this same code, so
## the two policy kinds are strictly comparable and a baseline is legal by
## construction. It sits OUTSIDE the determinism boundary (ctf's rule: recorded
## bytes, not re-run logic) and may therefore use floating point — the byte it
## returns is what the wasm viewer replays, and this file never runs there.
##
## It keeps NO memory across ticks except the per-body error-diffusion
## accumulator and the last drive bearing, and no knowledge of the other seat's
## intent, note, say, prompt or policy label (tests/test_observation.nim
## asserts the signature cannot see them).

import std/math
import sim, intents

const
  RimGuardUmDefault* = 600_000
  ChargeLeadTicksDefault* = 4
  LiftEngageUmDefault* = 620_000
  CircleRadiusUm* = 1_400_000
  ParkRadiusUm* = 300_000

type
  BaselineParams* = object
    ## The three tunables. `tools/tune_baselines.nim` sweeps them over a
    ## bounded grid, `tools/ci/baseline_tuning.json` records the sweep's pick,
    ## and tests/test_tuning.nim asserts the shipped defaults still equal it.
    ## THE PHYSICS CONSTANTS ARE NOT SWEPT AND ARE NOT TUNABLE: if `pusher`
    ## cannot beat `anchor`, the sweep moves these three numbers, not the sim.
    rimGuardUm*: int
    chargeLeadTicks*: int
    liftEngageUm*: int

  ControlState* = object
    acc*: array[BodyCount, float]     ## error-diffusion accumulator, [0, 1)
    lastDrive*: array[BodyCount, int32]
    params*: BaselineParams

proc defaultBaselineParams*(): BaselineParams =
  BaselineParams(
    rimGuardUm: RimGuardUmDefault,
    chargeLeadTicks: ChargeLeadTicksDefault,
    liftEngageUm: LiftEngageUmDefault)

proc initControlState*(): ControlState =
  result.params = defaultBaselineParams()

proc contactRangeUm*(b: Body): int32 =
  ## How far apart two torso centres can be while one bug's foot can still
  ## touch the other's torso: my reach plus my foot's radius plus its torso's.
  b.reach + FootRadius + TorsoRadius

proc inContact*(sim: SimServer, bodyIndex: int): bool =
  ## True when this bug's legs can reach the other bug's torso. The controller
  ## reads it; the physics uses the swept disc test, which is strictly finer.
  let
    me = sim.bodies[bodyIndex]
    foe = sim.bodies[1 - bodyIndex]
  distUm(me.px, me.py, foe.px, foe.py) <= me.contactRangeUm()

proc unitOf(x, y: float): tuple[x, y: float] =
  let len = sqrt(x * x + y * y)
  if len < 1.0e-9: (1.0, 0.0) else: (x / len, y / len)

proc driveIndexFor(dx, dy: float): int32 =
  ## The nearest of the SIXTEEN drive bearings (direction index 2*drive) to a
  ## sim-space direction, by dot product against the committed table.
  let unit = unitOf(dx, dy)
  var
    best = 0'i32
    bestDot = -1.0e30
  for d in 0 ..< 16:
    let
      idx = dirIndex(int32(2 * d))
      dot = unit.x * float(dirX(idx)) + unit.y * float(dirY(idx))
    if dot > bestDot:
      bestDot = dot
      best = int32(d)
  best

proc resolveAuto(sim: SimServer, bodyIndex: int, intent: BugIntent,
                 contact: bool): int32 =
  ## `posture_bias: auto`, exactly as the system prompt documents it.
  let
    me = sim.bodies[bodyIndex]
    foe = sim.bodies[1 - bodyIndex]
    gap = distUm(me.px, me.py, foe.px, foe.py)
  if intent.stance == stanceLift and contact:
    return int32(ord(postureLift))
  if intent.stance == stanceBrace:
    return int32(ord(postureLow))
  if gap > 1_200_000:
    return int32(ord(postureHigh))
  if contact:
    return int32(ord(postureLow))
  int32(ord(postureEven))

proc driveCommand*(ctl: var ControlState, sim: SimServer, bodyIndex: int,
                   intent: BugIntent, tick: int): uint8 =
  ## The command byte for one bug this tick. A prone bug, or any phase other
  ## than `Playing`, forces `cmd = 0`.
  if bodyIndex < 0 or bodyIndex >= BodyCount:
    return 0
  let me = sim.bodies[bodyIndex]
  if me.downTicks > 0 or sim.phase != Playing:
    return 0
  let
    foe = sim.bodies[1 - bodyIndex]
    contact = sim.inContact(bodyIndex)
    px = float(me.px)
    py = float(me.py)
    qx = float(foe.px)
    qy = float(foe.py)
    cx = float(RingCentreX)
    cy = float(RingCentreY)
    gapUm = float(distUm(me.px, me.py, foe.px, foe.py))

  ## 1. the aim point.
  var
    ax = qx
    ay = qy
  case intent.aim
  of aimFoe:
    ax = qx + float(foe.vx) * float(intent.leadTicks)
    ay = qy + float(foe.vy) * float(intent.leadTicks)
  of aimCentre:
    ax = cx
    ay = cy
  of aimBearing:
    let idx = dirIndex(int32((intent.bearingDeg * 32 + 180) div 360))
    ax = px + 4_000_000.0 * float(dirX(idx)) / float(Q12)
    ay = py + 4_000_000.0 * float(dirY(idx)) / float(Q12)

  ## 2. the goal bearing, as a sim-space direction.
  var
    gx = ax - px
    gy = ay - py
  var goalDistUm = sqrt(gx * gx + gy * gy)
  case intent.stance
  of stanceCharge, stanceBrace:
    discard                       ## face what you are driving into / absorbing
  of stanceCircle:
    let
      rx = px - qx
      ry = py - qy
      r = unitOf(rx, ry)
      tangent =
        if intent.circleDir >= 0: (x: r.y, y: -r.x)   ## view counter-clockwise
        else: (x: -r.y, y: r.x)
      ## `r` points FROM the foe TO me, so a NEGATIVE bias (too far out) adds a
      ## pull toward the foe and a positive one (too close) pushes away: the
      ## orbit radius converges on CircleRadiusUm from either side. The sign
      ## matters — inverted, a long-range circle drives straight at the rim.
      bias = (float(CircleRadiusUm) - gapUm) / float(CircleRadiusUm)
    gx = tangent.x + bias * r.x
    gy = tangent.y + bias * r.y
    goalDistUm = gapUm
  of stanceLift:
    if gapUm <= float(ctl.params.liftEngageUm):
      gx = qx - px               ## you need the CONTACT, not the lead
      gy = qy - py
      goalDistUm = gapUm
  of stanceRetreat:
    ## Back off AND inward. When the two pulls cancel exactly — the ring centre
    ## directly behind you from the other bug — the sum is the zero vector and
    ## a naive normalise would point east; falling back to `away` keeps the
    ## retreat a retreat instead of a charge.
    let
      away = unitOf(px - qx, py - qy)
      inward = unitOf(cx - px, cy - py)
      sumX = away.x + inward.x
      sumY = away.y + inward.y
    if sqrt(sumX * sumX + sumY * sumY) < 0.05:
      gx = away.x
      gy = away.y
    else:
      gx = sumX
      gy = sumY
    goalDistUm = gapUm
  of stanceCentre:
    gx = cx - px
    gy = cy - py
    goalDistUm = sqrt(gx * gx + gy * gy)

  ## 3. the rim guard — ALWAYS, every stance. This is the one thing that stops
  ## the controller walking a bug out of its own ring; halving it at aggression
  ## 10 is the only way a policy can order an all-in push, and the system
  ## prompt says so, so it is a choice rather than a trap.
  let
    d = float(distUm(me.px, me.py, RingCentreX, RingCentreY))
    guard = float(max(1, ctl.params.rimGuardUm))
    ringR = float(sim.ringRadiusNow)
    outward = unitOf(px - cx, py - cy)
    ## How fast the bug is moving AWAY from the ring centre, and how far it
    ## would still travel before it could stop. A guard that only looks at
    ## where the bug IS can be outrun: at `high` posture a bug crosses the last
    ## 0.6 m in four ticks, and by then pointing it inward is too late. The
    ## stopping term is v^2 / (2a) with a the effective inward acceleration a
    ## braking bug gets (its own thrust plus friction, ~4 000 um/tick^2).
    radial = max(0.0, float(me.vx) * outward.x + float(me.vy) * outward.y)
    stopping = radial * radial / 8_000.0
  var w = clamp((d + stopping - (ringR - guard)) * 100.0 / guard, 0.0, 100.0)
  if intent.aggression >= 10:
    w = w / 2.0
  if w > 0.0:
    let
      goal = unitOf(gx, gy)
      inward = unitOf(cx - px, cy - py)
      k = w / 100.0
    gx = goal.x * (1.0 - k) + inward.x * k
    gy = goal.y * (1.0 - k) + inward.y * k

  ## 4. posture.
  var postureIdx =
    case intent.postureBias
    of biasLow: int32(ord(postureLow))
    of biasEven: int32(ord(postureEven))
    of biasHigh: int32(ord(postureHigh))
    of biasAuto: resolveAuto(sim, bodyIndex, intent, contact)
  if w >= 60.0:
    postureIdx = int32(ord(postureLow))

  ## 5. effort — continuous, then DUTY-CYCLED across ticks. 24 bytes a second
  ## is where the continuity lives, not in one byte's amplitude.
  var e = 3.0 * float(intent.aggression) / 10.0
  case intent.stance
  of stanceBrace:
    if not contact:
      e = e * 0.35
    if float(me.speedUm()) < 2_083.0:
      ## Within 0.05 m/s of a standstill a brace stops pushing entirely: it is
      ## a plant, not a walk.
      e = 0.0
  of stanceCentre, stanceRetreat:
    if goalDistUm < float(ParkRadiusUm):
      e = e * (goalDistUm / float(ParkRadiusUm))
  else:
    discard
  ## THE RIM GUARD IS A BRAKE, NOT JUST A STEER. Redirecting a coasting bug
  ## inward is useless if it has no thrust to arrest itself with: a `retreat` at
  ## aggression 2 carries barely half an effort level, and a bug that drifted
  ## outward at 0.1 m/tick would cross the rim while pointing the right way.
  ## Inside the guard band the autopilot pushes as hard as the guard is strong,
  ## which is exactly what "it keeps you off the rim" means. At aggression 10
  ## `w` is already halved, so the braking is halved with it — the documented
  ## trade survives.
  if w > 0.0:
    e = max(e, 3.0 * w / 100.0)

  var effort = int32(floor(e + ctl.acc[bodyIndex]))
  effort = clamp(effort, 0'i32, 3'i32)
  ctl.acc[bodyIndex] = clamp(ctl.acc[bodyIndex] + e - float(effort), 0.0, 1.0)

  ## 6. quantise.
  let driveIdx = driveIndexFor(gx, gy)
  ctl.lastDrive[bodyIndex] = driveIdx
  encodeCommand(driveIdx, postureIdx, effort)
