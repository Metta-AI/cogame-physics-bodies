## The leg kinematic and the command-byte decode: everything that turns one
## recorded `uint8` into the forces the ring physics applies.
##
## There is no joint solver, no inverse kinematics and no ragdoll here. A bug
## is FIVE collision discs — one torso, four feet — plus a yaw servo, and this
## file is the whole of the multibody model. That is stated as a reduction, not
## dressed up as MuJoCo.
##
## No floating point (grep-enforced, tests/test_determinism.nim 2d).

import sim_types, trig

proc decodeCommand*(cmd: uint8): tuple[drive, posture, effort: int32] =
  ## The recorded action, unpacked. 16 drive bearings x 4 postures x 4 effort
  ## levels is exactly 256, so the byte uses its whole range: NO value is
  ## reserved and no value needs repair.
  let v = int32(cmd)
  (v div 16, (v div 4) mod 4, v mod 4)

proc encodeCommand*(drive, posture, effort: int32): uint8 =
  ## The inverse, clamped. The controller is the only caller.
  uint8(clamp(drive, 0, 15) * 16 + clamp(posture, 0, 3) * 4 +
    clamp(effort, 0, 3))

proc driveDirIndex*(drive: int32): int32 =
  ## A drive field is a BEARING: direction index `2 * drive`, i.e. the 16
  ## bearings are 22.5 degrees apart.
  dirIndex(2 * drive)

proc posture*(body: Body): int32 =
  ## The posture the body's last applied byte selected.
  decodeCommand(body.lastCmd).posture

proc effort*(body: Body): int32 =
  ## The leg load the body's last applied byte selected. A prone bug applies
  ## none (the step loop zeroes it before the dynamics).
  decodeCommand(body.lastCmd).effort

proc drive*(body: Body): int32 =
  decodeCommand(body.lastCmd).drive

proc reachForPosture*(posture: int32): int32 =
  ## Leg reach is a PURE function of posture — that is why the byte does not
  ## have to carry it.
  ReachByPosture[clamp(int(posture), 0, 3)]

proc footDirIndex*(body: Body, leg: int): int32 =
  ## Leg `k`'s foot direction index: the torso heading plus the leg's mount
  ## offset in the torso's own frame.
  dirIndex(body.hMilli div 1000 + LegBaseIdx[leg])

proc refreshLegs*(body: var Body, ringCentreX, ringCentreY,
                  ringRadiusNow: int32) =
  ## Recomputes leg reach, the four foot positions and `groundedCount` from
  ## `(p, hMilli, posture, downTicks, ringRadiusNow)`.
  ##
  ## A foot beyond the rim finds NO FLOOR: it cannot push and it cannot
  ## recover tilt. Standing near the edge costing you traction and stability
  ## is the whole tactical spine of the game, and it lives in these six lines.
  body.reach = reachForPosture(body.posture())
  var grounded = 0'i32
  for k in 0 ..< LegCount:
    let
      d = body.footDirIndex(k)
      r = int64(body.reach)
    body.footX[k] = body.px + int32((r * int64(dirX(d))) div int64(Q12))
    body.footY[k] = body.py + int32((r * int64(dirY(d))) div int64(Q12))
    let onFloor =
      body.downTicks == 0 and
      distUm(body.footX[k], body.footY[k], ringCentreX, ringCentreY) <=
        ringRadiusNow
    body.footGrounded[k] = onFloor
    if onFloor:
      inc grounded
  body.groundedCount = grounded

proc stepYaw*(body: var Body) =
  ## The yaw servo: a bug TURNS TO FACE where it pushes. A prone body skips
  ## the self-driven term (4.1) but keeps drag and the clamp (4.2-4.3), so it
  ## still spins down while it lies there.
  let
    postureIdx = clamp(int(body.posture()), 0, 3)
    target = 2'i32 * body.drive() * 1000'i32
    dMilli = shortestMilli(target - body.hMilli)
  if body.downTicks == 0:
    let accel = clamp(dMilli div 8, -YawAccelMilli, YawAccelMilli)
    body.omegaMilli = int32(int64(body.omegaMilli) +
      (int64(accel) * int64(YawGainPct[postureIdx])) div 100'i64)
  ## Nim's `div` truncates toward zero, so yaw drag is symmetric under
  ## negation — a clockwise and an anticlockwise spin decay identically.
  body.omegaMilli = int32(int64(body.omegaMilli) -
    (int64(body.omegaMilli) * int64(YawDragNumPer1024)) div 1024'i64)
  body.omegaMilli = clamp(body.omegaMilli, -MaxYawMilli, MaxYawMilli)
  body.hMilli = ((body.hMilli + body.omegaMilli) mod 32000 + 32000) mod 32000

proc headingDirIndex*(body: Body): int32 =
  dirIndex(body.hMilli div 1000)

proc speedUm*(body: Body): int32 =
  lenUm(body.vx, body.vy)

proc isDown*(body: Body): bool =
  body.downTicks > 0
