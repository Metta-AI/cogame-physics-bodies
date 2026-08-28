## THE RING: the body/ring physics core and the step loop.
##
## The resolution order below is EXACT and runs every tick with no exceptions.
## It is the determinism boundary: the controller and the LLM live outside it
## (their output is the recorded command byte), and everything inside is
## integer-only so the native amd64 server and the emscripten/wasm32 replay
## viewer produce the same `gameHash` chain bit for bit.
##
## `sim.nim` imports and RE-EXPORTS the other sim modules, so `import
## bodies/sim` still sees everything (ctf's split, kept).

import sim_types, trig, body, ring, sim_config, sim_state, roster
export sim_types, trig, body, ring, sim_config, sim_state, roster

proc resetBodyForRound(sim: var SimServer, bodyIndex: int) =
  let place = startPlacement(sim.startAxis[sim.roundIndex], sim.roundIndex,
    bodyIndex)
  var b = Body()
  b.px = place.x
  b.py = place.y
  b.hMilli = place.hMilli
  b.lastCmd = 0
  ## Episode-long counters survive a round; per-round ones do not.
  b.contacts = sim.bodies[bodyIndex].contacts
  b.shoveImpulseUm = sim.bodies[bodyIndex].shoveImpulseUm
  sim.bodies[bodyIndex] = b
  sim.bodies[bodyIndex].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)

proc startRound*(sim: var SimServer) =
  ## The first tick of round `roundIndex`: full ring, both bugs at rest on the
  ## seeded start axis at `StartRadius`, facing each other, with the END SWAP
  ## applied on odd rounds.
  sim.ringRadiusNow = int32(sim.config.ringRadiusUm)
  sim.roundTick = 0
  sim.resetLeft = 0
  for i in 0 ..< BodyCount:
    sim.resetBodyForRound(i)
  sim.phase = Playing
  sim.logGameEvent("round " & $(sim.roundIndex + 1) & " of " &
    $sim.config.maxRounds & " — ring " &
    $(sim.ringRadiusNow div 1000) & " mm and closing")
  sim.emitEvent(PhaseChange, detail = "round_start",
    amount = int(sim.roundIndex) + 1)

proc initSimServer*(config: GameConfig): SimServer =
  ## A fresh episode. EVERY draw happens here: the seat/body permutation and
  ## all five start axes, so `rngDraws` is exactly 6 for every episode of every
  ## variant and the whole seeded layout is a pure function of `config.seed`
  ## (tests/test_determinism.nim 2f).
  result.config = config
  result.rngState = seedStream(config.seed)
  result.rngDraws = 0
  result.perm = drawPerm(result.rngState, result.rngDraws)
  for i in 0 ..< BodyCount:
    result.invPerm[int(result.perm[i])] = int32(i)
  for r in 0 ..< MaxRoundsDefault:
    result.startAxis[r] = drawStartAxis(result.rngState, result.rngDraws)
  result.axisDrawn = int32(MaxRoundsDefault)
  result.players = @[]
  result.ringRadiusNow = int32(config.ringRadiusUm)
  result.roundIndex = 0
  result.roundTick = 0
  result.resetLeft = 0
  result.roundLog = @[]
  result.phase = Lobby
  result.tickCount = 0
  result.gameStartTick = 0
  result.winner = -1
  result.stopTick = -1
  result.gameEventLoggingEnabled = true
  result.feedIntents = @[]
  result.events = @[]
  for i in 0 ..< BodyCount:
    result.seatNames[i] = ""
    result.seatPolicyKind[i] = ""
  ## Bodies are placed for round 0 up front so the lobby already shows the
  ## ring with two bugs standing in it rather than two discs at the origin.
  for i in 0 ..< BodyCount:
    result.resetBodyForRound(i)

# ---------------------------------------------------------------------------
#  Scoring
# ---------------------------------------------------------------------------

proc bonusMicro(reason: RoundReason): int64 =
  case reason
  of roundRingOut: RingOutBonusMicro
  of roundKnockout: KnockoutBonusMicro
  else: 0'i64

proc bankRound*(sim: var SimServer, winner: int32, reason: RoundReason,
                ticks: int32) =
  ## The ONE proc that banks a round, used identically on record and on
  ## playback. A fact banked outside the hashed step function hash-mismatches
  ## at the stop tick (cogame-particle-worlds 13c66d7), so this is called from
  ## inside `step` and from nowhere else.
  sim.roundLog.add RoundLogEntry(
    round: sim.roundIndex + 1,
    winner: winner,
    reason: reason,
    ticks: ticks,
    knockdowns: [sim.bodies[0].knockdowns, sim.bodies[1].knockdowns]
  )
  if winner >= 0:
    sim.roundsWon[winner] += 1
    sim.roundMicro[winner] += RoundWinMicro + bonusMicro(reason)
    if reason == roundRingOut:
      sim.ringOuts[winner] += 1
    elif reason == roundKnockout:
      sim.knockouts[winner] += 1
  sim.logGameEvent("round " & $(sim.roundIndex + 1) & " ended " & $reason &
    " — winner " & (if winner < 0: "draw" else: alias(int(winner))))
  sim.emitEvent(RoundEnd, source = int(winner), detail = $reason,
    amount = int(ticks))

proc finishMatch*(sim: var SimServer, reason, endRule: string) =
  ## Ends the episode. `winner` is a BODY index; `isDraw` is read before it by
  ## every consumer (the endcard checks a draw before a winner).
  sim.phase = GameOver
  sim.endReason = reason
  sim.endRule = endRule
  if sim.roundsWon[0] > sim.roundsWon[1]:
    sim.winner = 0
    sim.isDraw = false
  elif sim.roundsWon[1] > sim.roundsWon[0]:
    sim.winner = 1
    sim.isDraw = false
  else:
    sim.winner = -1
    sim.isDraw = true
  sim.timeLimitReached = endRule == EndRuleFullTime or
    endRule == EndRuleWallClock
  sim.logGameEvent("match over: " & reason & "/" & endRule & " — rounds " &
    $sim.roundsWon[0] & "-" & $sim.roundsWon[1])
  sim.emitEvent(PhaseChange, detail = "gameover", amount = ord(GameOver))

# ---------------------------------------------------------------------------
#  The step
# ---------------------------------------------------------------------------

proc applyDynamics(sim: var SimServer, bodyIndex: int, cmd: uint8) =
  ## Steps 4 and 5: the yaw servo, then traction and linear dynamics.
  let decoded = decodeCommand(cmd)
  var b = sim.bodies[bodyIndex]
  b.lastCmd = cmd
  let postureIdx = clamp(int(decoded.posture), 0, 3)
  b.stepYaw()

  var effort = decoded.effort
  var fricIdx = postureIdx
  if b.downTicks > 0:
    ## A prone bug cannot push, and it scrubs off speed fast.
    effort = 0
    b.downTicks -= 1
    fricIdx = 0

  if effort > 0 and b.groundedCount > 0:
    let accel = int32(
      (int64(ThrustUnit) * int64(effort) * int64(TractionMulPct[postureIdx]) *
        int64(b.groundedCount)) div (3'i64 * 100'i64 * 4'i64))
    let d = driveDirIndex(decoded.drive)
    b.vx = int32(int64(b.vx) + (int64(accel) * int64(dirX(d))) div int64(Q12))
    b.vy = int32(int64(b.vy) + (int64(accel) * int64(dirY(d))) div int64(Q12))

  ## Friction. Nim's `div` truncates toward zero, so it is symmetric under
  ## negation: a bug drifting left decays exactly like one drifting right.
  b.vx = int32(int64(b.vx) -
    (int64(b.vx) * int64(FricNumPer1024[fricIdx])) div 1024'i64)
  b.vy = int32(int64(b.vy) -
    (int64(b.vy) * int64(FricNumPer1024[fricIdx])) div 1024'i64)

  ## Integer friction cannot reach zero on its own (see RestFloorUm): a bug
  ## inside the rest band is snapped to rest so a coast really does end.
  if abs(b.vx) < RestFloorUm and abs(b.vy) < RestFloorUm:
    b.vx = 0
    b.vy = 0

  ## Per-posture speed clamp. Terminal speeds are set by FRICTION, not by this
  ## clamp (see the arithmetic in docs/RULES.md); the clamp is the ceiling.
  let cap = MaxSpeedByPosture[postureIdx]
  let speedSq = int64(b.vx) * int64(b.vx) + int64(b.vy) * int64(b.vy)
  if speedSq > int64(cap) * int64(cap):
    let len = max(1'i64, isqrt(speedSq))
    b.vx = int32((int64(b.vx) * int64(cap)) div len)
    b.vy = int32((int64(b.vy) * int64(cap)) div len)

  b.px += b.vx
  b.py += b.vy
  sim.bodies[bodyIndex] = b
  if bodyIndex < BodyCount:
    sim.effortSum[bodyIndex] += int64(effort)
    sim.effortTicks[bodyIndex] += 1

proc discPairs(sim: SimServer): array[25, DiscPair] =
  ## The five discs of body 0 against the five of body 1, in ONE fixed order:
  ## outer loop body 0's index, inner loop body 1's, torso first. Ten of the
  ## twenty-five entries are live at once (a prone bug folds its legs in, so
  ## its collision set is the torso disc alone), and the array is fixed-size so
  ## nothing allocates inside the step.
  let
    a = sim.bodies[0]
    b = sim.bodies[1]
  var n = 0
  for ia in -1 ..< LegCount:
    if ia >= 0 and (a.downTicks > 0 or not a.footGrounded[ia]):
      ## An airborne foot is over the rim: no floor, and nothing to shove
      ## with. It still cannot collide, which is what makes the edge dangerous
      ## rather than merely slow.
      discard
    for ib in -1 ..< LegCount:
      var pair = DiscPair(legA: ia, legB: ib)
      if ia < 0:
        pair.ax = a.px
        pair.ay = a.py
        pair.ra = TorsoRadius
      else:
        pair.ax = a.footX[ia]
        pair.ay = a.footY[ia]
        pair.ra = FootRadius
      if ib < 0:
        pair.bx = b.px
        pair.by = b.py
        pair.rb = TorsoRadius
      else:
        pair.bx = b.footX[ib]
        pair.by = b.footY[ib]
        pair.rb = FootRadius
      result[n] = pair
      inc n

proc resolveContacts(sim: var SimServer) =
  ## Step 6, the sumo core. Ten live disc pairs, ONE fixed order, every test
  ## SWEPT so a fast foot cannot tunnel through a torso between two ticks.
  ##
  ## The SHOVE is deliberately not a closed-system impulse: the momentum comes
  ## from the FLOOR, not from the receiver, and a well-planted pusher
  ## (groundedCount 4) takes ZERO recoil. That is exactly why bracing on all
  ## four legs before you shove is the right play.
  ##
  ## Both push directions are evaluated for every pair, so nothing in this loop
  ## depends on which body happens to be index 0: two loaded feet meeting push
  ## each other apart, and a mirror-image state resolves to a mirror-image
  ## result (tests/test_physics.nim pins the zero-recoil and momentum claims).
  let pairs = sim.discPairs()
  let
    relDx = int64(sim.bodies[0].vx) - int64(sim.bodies[1].vx)
    relDy = int64(sim.bodies[0].vy) - int64(sim.bodies[1].vy)
  for pair in pairs:
    ## Prone bugs fold their legs in: only the torso disc collides, and a foot
    ## over the rim has no floor under it to push from.
    if pair.legA >= 0 and
        (sim.bodies[0].downTicks > 0 or
         not sim.bodies[0].footGrounded[pair.legA]):
      continue
    if pair.legB >= 0 and
        (sim.bodies[1].downTicks > 0 or
         not sim.bodies[1].footGrounded[pair.legB]):
      continue
    let touch = discsTouch(pair, relDx, relDy)
    if not touch.hit:
      continue
    let
      nIdx = normalIndexBetween(pair.ax, pair.ay, pair.bx, pair.by)
      nx = dirX(nIdx)
      ny = dirY(nIdx)
      pen = max(0'i32, pair.ra + pair.rb - touch.dist)

    ## 6.2 positional split. A prone body takes the WHOLE penetration and the
    ## upright one takes none — a bug on its back is shovable, and that is the
    ## 1.5-second window a knockdown buys.
    var shareA = pen div 2
    var shareB = pen - shareA
    if sim.bodies[0].downTicks > 0 and sim.bodies[1].downTicks == 0:
      shareA = pen
      shareB = 0
    elif sim.bodies[1].downTicks > 0 and sim.bodies[0].downTicks == 0:
      shareA = 0
      shareB = pen
    sim.bodies[0].px += int32((int64(shareA) * int64(nx)) div int64(Q12))
    sim.bodies[0].py += int32((int64(shareA) * int64(ny)) div int64(Q12))
    sim.bodies[1].px -= int32((int64(shareB) * int64(nx)) div int64(Q12))
    sim.bodies[1].py -= int32((int64(shareB) * int64(ny)) div int64(Q12))

    ## 6.3 normal impulse. Equal masses, hence the /2.
    let vn = int32((
      (int64(sim.bodies[0].vx) - int64(sim.bodies[1].vx)) * int64(nx) +
      (int64(sim.bodies[0].vy) - int64(sim.bodies[1].vy)) * int64(ny)) div
      int64(Q12))
    var j = 0'i32
    if vn < 0:
      j = int32((-int64(vn) * (int64(Q12) + int64(Restitution))) div
        (2'i64 * int64(Q12)))
      sim.bodies[0].vx += int32((int64(j) * int64(nx)) div int64(Q12))
      sim.bodies[0].vy += int32((int64(j) * int64(ny)) div int64(Q12))
      sim.bodies[1].vx -= int32((int64(j) * int64(nx)) div int64(Q12))
      sim.bodies[1].vy -= int32((int64(j) * int64(ny)) div int64(Q12))

    ## 6.4 the shove, evaluated for BOTH directions. `shoveInto[r]` is what
    ## body `r` receives; `+n` pushes body 0 away from body 1 and `-n` pushes
    ## body 1 away from body 0.
    var
      shoveInto: array[BodyCount, int32]
      liftInto: array[BodyCount, bool]
    for pusher in 0 ..< BodyCount:
      let leg = if pusher == 0: pair.legA else: pair.legB
      if leg < 0:
        continue                      ## a torso cannot shove; only a foot can
      let pb = sim.bodies[pusher]
      if pb.effort() <= 0 or pb.downTicks > 0:
        continue
      let
        receiver = 1 - pusher
        postureIdx = clamp(int(pb.posture()), 0, 3)
        shove = int32((int64(ShoveUnit) * int64(pb.effort()) *
          int64(ShoveMulPct[postureIdx])) div (3'i64 * 100'i64))
        ## The receiver is pushed AWAY from the pusher: body 1 along -n, body 0
        ## along +n.
        sign = if receiver == 0: 1'i64 else: -1'i64
      shoveInto[receiver] += shove
      if postureIdx == ord(postureLift):
        liftInto[receiver] = true
      sim.bodies[receiver].vx += int32(
        (sign * int64(shove) * int64(nx)) div int64(Q12))
      sim.bodies[receiver].vy += int32(
        (sign * int64(shove) * int64(ny)) div int64(Q12))
      ## Recoil scales with how badly planted the pusher is: four grounded legs
      ## take exactly zero.
      let recoil = int32(
        (int64(shove) * (4'i64 - int64(pb.groundedCount))) div 8'i64)
      sim.bodies[pusher].vx -= int32(
        (sign * int64(recoil) * int64(nx)) div int64(Q12))
      sim.bodies[pusher].vy -= int32(
        (sign * int64(recoil) * int64(ny)) div int64(Q12))
      sim.bodies[pusher].shoveImpulseUm += int64(shove)
      if liftInto[receiver]:
        ## What the lifter loads onto ITSELF: a lift is a risk, not a freebie.
        sim.bodies[pusher].tipMilli += int32(
          int64(LiftSelfTipMilli) * int64(pb.effort()) div 3'i64)

    let
      contactX = pair.bx + (pair.ax - pair.bx) div 2
      contactY = pair.by + (pair.ay - pair.by) div 2

    for recvIdx in 0 ..< BodyCount:
      let force = int64(j) + int64(shoveInto[recvIdx])
      if force <= 0:
        continue
      ## 6.5 contact torque: an off-centre hit SPINS you.
      let
        sign = if recvIdx == 0: 1'i64 else: -1'i64
        rx = contactX - sim.bodies[recvIdx].px
        ry = contactY - sim.bodies[recvIdx].py
        torque = crossQ12(rx, ry,
          int32((sign * force * int64(nx)) div int64(Q12)),
          int32((sign * force * int64(ny)) div int64(Q12)))
        delta = int32(clamp((torque * 1000'i64) div
          (int64(Q12) * int64(TorsoRadius)),
          -int64(MaxYawMilli div 2), int64(MaxYawMilli div 2)))
      sim.bodies[recvIdx].omegaMilli = clamp(
        sim.bodies[recvIdx].omegaMilli + delta, -MaxYawMilli, MaxYawMilli)

      ## 6.6 tilt load, scaled by the RECEIVER's posture: low absorbs, high
      ## tips, and a lift levers you over on top of everything else.
      let
        recvPosture = clamp(int(sim.bodies[recvIdx].posture()), 0, 3)
        excess = max(0'i64, force - int64(TipImpulseThreshUm))
        loaded = int32((excess div int64(TipPerUmDiv)) *
          int64(TipRecvMulPct[recvPosture]) div 100'i64)
      sim.bodies[recvIdx].tipMilli += loaded
      if liftInto[recvIdx]:
        let pushEffort = sim.bodies[1 - recvIdx].effort()
        sim.bodies[recvIdx].tipMilli += int32(
          (int64(LiftTipMilli) * int64(pushEffort) div 3'i64) *
            int64(TipRecvMulPct[recvPosture]) div 100'i64)

      ## 6.7 counters + the `contact` event.
      sim.bodies[recvIdx].contacts += 1
      if force >= int64(TipImpulseThreshUm):
        sim.lastFx = ContactFx(tick: int32(sim.tickCount), x: contactX,
          y: contactY, impulseUm: int32(force), normalIdx: nIdx,
          lift: liftInto[recvIdx])
        sim.emitEvent(Contact, source = 1 - recvIdx, target = recvIdx,
          detail = $sim.bodies[recvIdx].posture(), amount = int(force),
          x = int(contactX), y = int(contactY))
        if shoveInto[recvIdx] > 0:
          sim.emitEvent(Shove, source = 1 - recvIdx, target = recvIdx,
            amount = int(shoveInto[recvIdx]), x = int(contactX),
            y = int(contactY))

  ## 6.8 both bodies clamped to MaxBodySpeedHard AFTER the pair loop, so a
  ## legal contact can never trip the step-12 fault guard.
  for i in 0 ..< BodyCount:
    let speedSq = int64(sim.bodies[i].vx) * int64(sim.bodies[i].vx) +
      int64(sim.bodies[i].vy) * int64(sim.bodies[i].vy)
    if speedSq > int64(MaxBodySpeedHard) * int64(MaxBodySpeedHard):
      let len = max(1'i64, isqrt(speedSq))
      sim.bodies[i].vx = int32(
        (int64(sim.bodies[i].vx) * int64(MaxBodySpeedHard)) div len)
      sim.bodies[i].vy = int32(
        (int64(sim.bodies[i].vy) * int64(MaxBodySpeedHard)) div len)

proc stepTilt(sim: var SimServer) =
  ## Step 7. Spin erodes your own stability; grounded legs recover it; full
  ## tilt puts you DOWN for 1.5 seconds, and three falls loses the round.
  for i in 0 ..< BodyCount:
    var b = sim.bodies[i]
    let before = b.tipMilli
    b.tipMilli += max(0'i32, (abs(b.omegaMilli) - SpinTipMilli) div 8)
    b.tipMilli -= (TipRecoverMilli * b.groundedCount) div 4
    b.tipMilli = clamp(b.tipMilli, 0'i32, TipDown)
    if b.tipMilli == TipDown and b.downTicks == 0:
      b.downTicks = int32(sim.config.downTicks)
      b.tipMilli = 0
      b.omegaMilli = b.omegaMilli div 4
      b.knockdowns += 1
      sim.knockdownsSuffered[i] += 1
      sim.bodies[i] = b
      sim.logGameEvent("KNOCKDOWN — " & alias(i) & " is down (" &
        $b.knockdowns & " of " & $sim.config.knockdownsToLose & ")")
      sim.emitEvent(Knockdown, target = i, amount = int(b.knockdowns),
        x = int(b.px), y = int(b.py))
      continue
    if before < 500 and b.tipMilli >= 500:
      sim.emitEvent(Stagger, target = i, amount = int(b.tipMilli),
        x = int(b.px), y = int(b.py))
    sim.bodies[i] = b

proc clampArena(sim: var SimServer) =
  ## Step 8. Only reachable AFTER a ring-out, while the loser is still sliding
  ## through the reset hold; it exists so no coordinate can leave the world.
  for i in 0 ..< BodyCount:
    if sim.bodies[i].px < TorsoRadius:
      sim.bodies[i].px = TorsoRadius
      sim.bodies[i].vx = 0
    elif sim.bodies[i].px > ArenaW - TorsoRadius:
      sim.bodies[i].px = ArenaW - TorsoRadius
      sim.bodies[i].vx = 0
    if sim.bodies[i].py < TorsoRadius:
      sim.bodies[i].py = TorsoRadius
      sim.bodies[i].vy = 0
    elif sim.bodies[i].py > ArenaH - TorsoRadius:
      sim.bodies[i].py = ArenaH - TorsoRadius
      sim.bodies[i].vy = 0

proc roundOutcome(sim: SimServer):
    tuple[ended: bool, winner: int32, reason: RoundReason] =
  ## Step 9's checks, in order — the FIRST that fires ends the round.
  result = (false, -1'i32, roundNone)
  let
    d0 = sim.bodies[0].distFromCentre()
    d1 = sim.bodies[1].distFromCentre()
    out0 = d0 > sim.ringRadiusNow
    out1 = d1 > sim.ringRadiusNow
  ## 9.1 ring-out.
  if out0 or out1:
    if out0 and out1:
      if abs(int64(d0) - int64(d1)) <= int64(CentreTieUm):
        return (true, -1'i32, roundDraw)
      return (true, (if d0 > d1: 1'i32 else: 0'i32), roundRingOut)
    return (true, (if out0: 1'i32 else: 0'i32), roundRingOut)
  ## 9.2 knockout: three falls in one round.
  for i in 0 ..< BodyCount:
    if sim.bodies[i].knockdowns >= int32(sim.config.knockdownsToLose):
      return (true, int32(1 - i), roundKnockout)
  ## 9.3 the round clock: fewer knockdowns first, then the CENTRE — in a
  ## shrinking ring, holding the middle is the virtue.
  if int(sim.roundTick) + 1 >= sim.config.roundTicks:
    if sim.bodies[0].knockdowns != sim.bodies[1].knockdowns:
      return (true,
        (if sim.bodies[0].knockdowns < sim.bodies[1].knockdowns: 0'i32
         else: 1'i32),
        roundDecision)
    if abs(int64(d0) - int64(d1)) <= int64(CentreTieUm):
      return (true, -1'i32, roundDraw)
    return (true, (if d0 < d1: 0'i32 else: 1'i32), roundDecision)

proc step*(sim: var SimServer, cmds: openArray[uint8]) =
  ## ONE tick. `cmds` is indexed by REPLAY INPUT ROW (see
  ## `roster.inputIndexOfBody`), which is the seat index whenever a seat drives
  ## the bug. Steps 1 and 2 of the resolution order (the turn boundary and the
  ## controller compile) happen OUTSIDE this proc, in the server, and only the
  ## bytes they produce reach here — which is why the wasm viewer re-derives
  ## the whole match from the action log without ever running either.
  case sim.phase
  of Lobby:
    inc sim.lobbyTicks
    sim.logLobbyWaiting()
    if sim.lobbyIsStarting() and
        sim.lobbyTicks >= sim.config.startWaitTicks:
      sim.gameStartTick = sim.tickCount
      sim.startRound()
    inc sim.tickCount
    return
  of GameOver:
    inc sim.gameOverTicks
    inc sim.tickCount
    return
  of Playing, RoundReset:
    discard

  ## Step 3: ring geometry, then leg reach / foot positions / groundedCount.
  sim.ringRadiusNow = ringRadiusAt(sim.config, sim.roundTick)
  for i in 0 ..< BodyCount:
    sim.bodies[i].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
    if sim.bodies[i].groundedCount < int32(LegCount) and
        sim.bodies[i].downTicks == 0:
      sim.emitEvent(RimSlip, target = i,
        amount = int(sim.bodies[i].groundedCount),
        x = int(sim.bodies[i].px), y = int(sim.bodies[i].py))

  ## Steps 4-5, in BODY index order — never seat order, which varies with
  ## `perm` and must never reorder the loop.
  for i in 0 ..< BodyCount:
    let cmd =
      if sim.phase == RoundReset: 0'u8
      else:
        let row = sim.inputIndexOfBody(i)
        if row >= 0 and row < cmds.len: cmds[row] else: 0'u8
    sim.applyDynamics(i, cmd)

  ## Step 6, then the legs move with their torsos before the tilt pass reads
  ## `groundedCount` again.
  for i in 0 ..< BodyCount:
    sim.bodies[i].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)
  sim.resolveContacts()
  for i in 0 ..< BodyCount:
    sim.bodies[i].refreshLegs(RingCentreX, RingCentreY, sim.ringRadiusNow)

  sim.stepTilt()
  sim.clampArena()

  ## Steps 9 and 10.
  var matchEnded = false
  if sim.phase == Playing:
    let outcome = sim.roundOutcome()
    if outcome.ended:
      if outcome.reason == roundRingOut and outcome.winner >= 0:
        sim.emitEvent(RingOut, target = int(1 - outcome.winner),
          amount = int(sim.ringRadiusNow))
      sim.bankRound(outcome.winner, outcome.reason, sim.roundTick + 1)
      sim.phase = RoundReset
      sim.resetLeft = int32(sim.config.resetTicks)
      ## Step 12: the clinch is checked the moment the round is banked.
      if int(max(sim.roundsWon[0], sim.roundsWon[1])) >=
          sim.config.roundsToClinch:
        sim.finishMatch(ReasonComplete, EndRuleMatchWon)
        matchEnded = true
      elif int(sim.roundIndex) + 1 >= sim.config.maxRounds:
        sim.finishMatch(ReasonComplete, EndRuleFullTime)
        matchEnded = true
    else:
      sim.roundTick += 1
  elif sim.phase == RoundReset:
    sim.resetLeft -= 1
    if sim.resetLeft <= 0:
      sim.roundIndex += 1
      if int(sim.roundIndex) >= sim.config.maxRounds:
        sim.finishMatch(ReasonComplete, EndRuleFullTime)
        matchEnded = true
      else:
        sim.startRound()

  inc sim.tickCount

  ## Step 12, the remaining episode checks. The invariant guard runs last so a
  ## legal contact that clamped itself is never reported as a fault.
  if not matchEnded and sim.phase != GameOver and
      sim.tickCount >= sim.effectiveMaxTicks():
    sim.finishMatch(ReasonComplete, EndRuleFullTime)
  sim.assertInvariants()

proc applyWallClockStop*(sim: var SimServer, tick: int32) =
  ## The ONE load-bearing wall-clock stop record, applied identically on record
  ## and on playback (cogame-particle-worlds 13c66d7: a stop applied only on
  ## the recording side hash-mismatches at the stop tick on every slow-LLM
  ## episode). The round in progress banks as a DRAW and the state is scored as
  ## it stands.
  if sim.phase == GameOver:
    return
  sim.stopTick = tick
  if sim.phase == Playing:
    sim.bankRound(-1'i32, roundDraw, sim.roundTick + 1)
  sim.finishMatch(ReasonDeadline, EndRuleWallClock)

proc matchScoreMicro*(sim: SimServer, bodyIndex: int): int64 =
  ## One bug's zero-sum score, in micro-points, for the chrome.
  if bodyIndex < 0 or bodyIndex >= BodyCount:
    return 0
  sim.roundMicro[bodyIndex] - sim.roundMicro[1 - bodyIndex]

proc turnIndexAt*(sim: SimServer, tick: int): int =
  ## Turn boundaries live on the GLOBAL tick grid and are NOT re-aligned when a
  ## round ends early: re-aligning would make the wall-clock budget a function
  ## of how the rounds went, and the budget is what the platform kills you for.
  tick div max(1, sim.config.turnTicks)

proc turnsPerEpisode*(sim: SimServer): int =
  max(1, sim.effectiveMaxTicks() div max(1, sim.config.turnTicks))
