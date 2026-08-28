## Hashing, logging, the lobby countdown and the tier-2 event sink.
##
## `gameHash` is the integrity chain: one value per tick in the replay, checked
## again in the browser by the wasm build of this same module. It mixes ONLY
## simulation state — never FX, notes, `say`, feed text or policy labels — so a
## cosmetic change can never invalidate a recorded episode, and a physics
## change always does.
##
## No floating point (grep-enforced, tests/test_determinism.nim 2d).

import sim_types, body

# ---------------------------------------------------------------------------
#  Lobby
# ---------------------------------------------------------------------------

proc seatCount*(sim: SimServer): int =
  clamp(sim.config.numAgents, 1, BodyCount)

proc lobbyIsStarting*(sim: SimServer): bool =
  ## The lobby is counting down to the first round: either every required seat
  ## is in, or the lobby budget expired with one missing. A no-show does NOT
  ## end the episode and does NOT hold the lobby open for the whole wall-clock
  ## budget — its bug plays the `pusher` baseline and the match is played
  ## (§End conditions). `lobbyNoShowSeat` is derived inside `step` from
  ## `lobbyTicks` and the recorded joins, so playback reaches the same verdict
  ## on the same tick.
  sim.phase == Lobby and
    (sim.players.len >= sim.config.minPlayers or sim.lobbyNoShowSeat >= 0)

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  if not sim.lobbyIsStarting():
    return sim.config.startWaitTicks
  max(0, sim.config.startWaitTicks - sim.lobbyTicks)

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  (sim.lobbyStartTicksRemaining() + TargetFps - 1) div TargetFps

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  ## The lobby budget. A seat that never connects does NOT end the episode:
  ## the no-show is declared to the platform and its bug is driven by the
  ## `pusher` baseline for the whole run.
  sim.phase == Lobby and sim.players.len < sim.seatCount() and
    sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks

proc effectiveMaxTicks*(sim: SimServer): int =
  if sim.config.maxTicks > 0: sim.config.maxTicks else: MaxTicks

proc gameTicksElapsed*(sim: SimServer): int =
  max(0, sim.tickCount - sim.gameStartTick)

# ---------------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------------

proc logGameEvent*(sim: SimServer, message: string) =
  if sim.gameEventLoggingEnabled:
    echo "physics-bodies t", sim.tickCount, ": ", message

proc logLobbyWaiting*(sim: SimServer) =
  if not sim.gameEventLoggingEnabled:
    return
  if sim.tickCount mod TargetFps != 0:
    return
  echo "physics-bodies: waiting for players (", sim.players.len, "/",
    sim.seatCount(), ")"

# ---------------------------------------------------------------------------
#  gameHash
# ---------------------------------------------------------------------------

proc mixHash(state: var uint64, value: uint64) =
  ## FNV-style mix in the `uint64` domain: identical on amd64 and wasm32,
  ## where Nim's `int` would not be.
  state = state xor value
  state = state * 0x100000001B3'u64
  state = state xor (state shr 29)

proc mixHashInt(state: var uint64, value: int64) =
  mixHash(state, cast[uint64](value))

proc mixHashBool(state: var uint64, value: bool) =
  mixHash(state, if value: 0x9E3779B9'u64 else: 0x85EBCA6B'u64)

proc gameHash*(sim: SimServer): uint64 =
  ## The per-tick integrity value. One divergent bit is caught at the tick it
  ## happens (`checkReplayHash`), surfaced as `mismatchTick` in the chrome and,
  ## in CI, as a hard failure.
  result = 0xCBF29CE484222325'u64
  mixHashInt(result, int64(sim.tickCount))
  mixHashInt(result, int64(ord(sim.phase)))
  mixHashInt(result, int64(sim.roundIndex))
  mixHashInt(result, int64(sim.roundTick))
  mixHashInt(result, int64(sim.resetLeft))
  mixHashInt(result, int64(sim.ringRadiusNow))
  for i in 0 ..< BodyCount:
    let b = sim.bodies[i]
    mixHashInt(result, int64(b.px))
    mixHashInt(result, int64(b.py))
    mixHashInt(result, int64(b.vx))
    mixHashInt(result, int64(b.vy))
    mixHashInt(result, int64(b.hMilli))
    mixHashInt(result, int64(b.omegaMilli))
    mixHashInt(result, int64(b.tipMilli))
    mixHashInt(result, int64(b.downTicks))
    mixHashInt(result, int64(b.groundedCount))
    mixHashInt(result, int64(b.knockdowns))
    mixHashInt(result, int64(b.contacts))
    mixHashInt(result, b.shoveImpulseUm)
  for i in 0 ..< BodyCount:
    mixHashInt(result, int64(sim.roundsWon[i]))
    mixHashInt(result, sim.roundMicro[i])
    mixHashInt(result, int64(sim.ringOuts[i]))
    mixHashInt(result, int64(sim.knockouts[i]))
    mixHashInt(result, int64(sim.knockdownsSuffered[i]))
    mixHashInt(result, int64(sim.perm[i]))
  mixHashInt(result, int64(sim.rngDraws))
  mixHashInt(result, int64(sim.roundLog.len))
  mixHashBool(result, sim.isDraw)
  mixHashInt(result, int64(sim.winner))
  mixHashInt(result, int64(sim.stopTick))

# ---------------------------------------------------------------------------
#  Tier-2 events (never hashed)
# ---------------------------------------------------------------------------

proc emitEvent*(sim: var SimServer, kind: SimEventKind, source = -1,
                target = -1, detail = "", amount = 0, x = 0, y = 0,
                content = "") =
  ## Appends one tier-2 analysis event. Guarded by `collectEvents` so a live
  ## server nobody is analysing keeps paying nothing.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount, kind: kind, source: source, target: target,
    detail: detail, amount: amount, x: x, y: y, content: content)

proc pushFeedIntent*(sim: var SimServer, record: string) =
  ## Records one `intent` control record for the broadcast feed. NOT hashed:
  ## this is what a spectator sees the LLM doing, and it must never be able to
  ## move the simulation. Bounded so a long match cannot grow it without limit.
  if record.len == 0 or record[0] != '{':
    return
  sim.feedIntents.add record
  if sim.feedIntents.len > 2 * BodyCount:
    sim.feedIntents.delete(0)

proc clearFeedIntents*(sim: var SimServer) =
  sim.feedIntents.setLen(0)

# ---------------------------------------------------------------------------
#  Guards
# ---------------------------------------------------------------------------

proc assertInvariants*(sim: SimServer) =
  ## The step-12 invariant guard. Every one of these is a `fault/sim_fault`
  ## end with a partial replay written, never a silent non-zero exit.
  for i in 0 ..< BodyCount:
    let b = sim.bodies[i]
    if b.px < TorsoRadius or b.px > ArenaW - TorsoRadius or
        b.py < TorsoRadius or b.py > ArenaH - TorsoRadius:
      raise newException(SimGuardError,
        "bug " & $i & " torso centre left the arena box at (" & $b.px & ", " &
          $b.py & ")")
    if b.speedUm() > MaxBodySpeedHard:
      raise newException(SimGuardError,
        "bug " & $i & " speed " & $b.speedUm() & " exceeds MaxBodySpeedHard")
    if b.hMilli < 0 or b.hMilli > 31999:
      raise newException(SimGuardError,
        "bug " & $i & " heading " & $b.hMilli & " is outside 0..31999")
    if b.tipMilli < 0 or b.tipMilli > TipDown:
      raise newException(SimGuardError,
        "bug " & $i & " tilt " & $b.tipMilli & " is outside 0..1000")
    if b.groundedCount < 0 or b.groundedCount > int32(LegCount):
      raise newException(SimGuardError,
        "bug " & $i & " groundedCount " & $b.groundedCount &
          " is outside 0..4")
  if sim.roundTick > int32(sim.config.roundTicks):
    raise newException(SimGuardError,
      "roundTick " & $sim.roundTick & " ran past roundTicks")
