## The replay codec wrapper, keyframes, the incremental precompute walk, lull
## spans, beat events and the transport commands.
##
## Kept from ctf's `src/ctf/replays.nim`: the whole codec wrapper, keyframes,
## `serializeReplaySim`/`deserializeReplaySim`, the incremental scan, lull
## spans, beat events, seek/speed/transport commands, `writeInputMaskChange`
## (used AS-IS: our command byte is a value and the codec's own change-only
## guard does the rest) and `checkReplayHash`.
##
## Two named edits: the keyframe serializer covers the new sim fields, and the
## magic is `COWLDPBD` with `GameName`/`GameVersion` from sim_types.

import std/json
import flatty
import bitworld/replays as replayCodec
import sim, global, broadcast, intents

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayScan* = ref object
    ## Working state of the incremental precompute walk: a second sim + player
    ## stepped from tick 0 that derives keyframes, the round-differential
    ## series, story beats and lull spans without touching the on-screen
    ## playback state.
    sim: SimServer
    builder: ReplayPlayer
    beatTracker: BroadcastTracker
    beatTicks: seq[int]
    lastLead: seq[int]
    interval: int
    maxTick: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int
      ## Index into `PlaybackSpeeds`, or `ReplayHalfSpeedIndex` (-1) for the
      ## replay-only 1/2x speed (one sim tick every other frame).
    halfPhase*: bool
      ## Frame parity while at 1/2x: a tick is spent only on the odd frames,
      ## toggled once per `advanceReplayPlayback` frame.
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
      ## First tick the match is actually being PLAYED. The Lobby span before
      ## it is dead air a spectator should never have to watch: playback
      ## auto-starts here, loops back here, and the scrubber is offset by it.
    leadSeries*: seq[seq[int]]
      ## [tick, roundMicro per bug] change-points across the WHOLE match,
      ## precomputed on the deterministic keyframe walk so the momentum graph
      ## draws its full-timeline shape at once.
    endHoldFrames*: int
    pendingSeekTick*: int
    skipLulls*: bool
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    scan: ReplayScan
    scanDone: bool

export PlaybackSpeeds
export replayCodec

const
  ReplayHalfSpeedIndex* = -1
    ## `speedIndex` sentinel for 1/2x playback: one sim tick every other frame.
    ## Replay-only — the live loop's `playbackSpeed` clamps it back to 1x.
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
  BeatKinds* = ["knockdown", "ring_out", "round_end", "match_point",
                "round_start", "gameover"]
    ## What counts as a BEAT — for the scrubber's timeline and for the lull
    ## scan, which must agree. §Record and event vocabulary: `contact`,
    ## `shove`, `stagger` and `rim_slip` are not beats, and neither is the
    ## `turn_end` tick marker.
  LullLeadTicks* = 2 * ReplayFps
  MinLullTicks* = 6 * ReplayFps
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64
  SeekTicksPerFrame* = 240
  BodiesReplayMagic* = "COWLDPBD"
  BodiesReplayFormatVersion = 1'u16
  BodiesReplaySpec = ReplaySpec(
    magic: BodiesReplayMagic,
    formatVersion: BodiesReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc writeInputMaskChange*(replayWriter: var ReplayWriter, time: uint32,
                           row: int, mask: uint8) =
  ## Writes one replay input event when a bug's applied COMMAND BYTE changes.
  ##
  ## Lives here rather than in server.nim because the byte log IS the replay's
  ## action stream: the tests that prove the recorded bytes re-simulate to the
  ## identical hash chain have to write it exactly the way the server does, and
  ## two copies of this would be two chances to drift.
  if row < 0 or row >= replayWriter.lastMasks.len:
    return
  if replayWriter.lastMasks[row] == mask:
    return
  replayWriter.writeInput(ReplayInput(time: time, player: uint8(row),
    keys: mask))
  replayWriter.lastMasks[row] = mask

proc openReplayWriter*(path, configJson: string): ReplayWriter =
  result = replayCodec.openReplayWriter(path, configJson, BodiesReplaySpec)
  ## Pre-size the action log to the BODY count, not the roster: a no-show seat
  ## must not stop its bug's bytes from being recorded, or playback would drive
  ## that bug from an all-zero log and diverge on the first tick.
  if result.enabled:
    result.lastMasks = newSeq[uint8](BodyCount)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, BodiesReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, BodiesReplaySpec)

proc serializeReplaySim*(sim: var SimServer): string =
  ## Serializes one simulation state for a replay keyframe. The static ring
  ## geometry and `perm` are already in the config JSON (ctf's rule for static
  ## bakes) but they are cheap and live on the sim, so the whole record goes:
  ## bodies, round state, tallies, the round log, the RNG state and the phase.
  sim.toFlatty()

proc deserializeReplaySim*(bytes: string): SimServer =
  bytes.fromFlatty(SimServer)

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.masks = newSeq[uint8](BodyCount)
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.pendingSeekTick = -1
  result.beatEvents = newJArray()

proc replaySpeed*(replay: ReplayPlayer): int =
  ## The integer step size (1 while at 1/2x — the fractional pace lives in
  ## `replayStepBudget`'s frame parity, not in a smaller step).
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(replay: ReplayPlayer): float =
  ## The speed the chrome shows: 0.5 at half speed, else the integer speed.
  if replay.speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(replay.replaySpeed())

proc replayMaxTick*(replay: ReplayPlayer): int =
  if replay.data.hashes.len == 0: 0 else: int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = newSeq[uint8](BodyCount)

proc saveReplayKeyframe(replay: ReplayPlayer,
                        sim: var SimServer): ReplayKeyframe =
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    hashIndex: replay.hashIndex,
    masks: replay.masks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(replay: var ReplayPlayer, sim: var SimServer,
                           keyframe: ReplayKeyframe) =
  let logging = sim.gameEventLoggingEnabled
  var restored = deserializeReplaySim(keyframe.simBytes)
  restored.gameEventLoggingEnabled = logging
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.hashIndex = keyframe.hashIndex
  replay.masks = keyframe.masks
  if replay.masks.len < BodyCount:
    replay.masks.setLen(BodyCount)
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins, leaves, command bytes and control records for the
  ## current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    ## A dropped seat's BUG keeps playing (its intent degrades to `pusher`), so
    ## the action log is indexed by body row and a leave never shifts it.
    sim.removePlayerAt(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    if int(input.player) < replay.masks.len:
      replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    ## CONTROL records ride the chat stream as JSON objects and are told apart
    ## from anything else by a leading '{'. Only `stop` is load-bearing: it is
    ## the one fact playback cannot re-derive from the action log, and it is
    ## applied by the SAME proc the recording side used
    ## (cogame-particle-worlds 13c66d7). `round` records re-derive inside
    ## `bankRound`, so re-applying one here would double-bank it.
    if chat.message.len > 0 and chat.message[0] == '{':
      var node: JsonNode = nil
      try:
        node = parseJson(chat.message)
      except CatchableError:
        node = nil
      if node != nil and node.kind == JObject:
        case node{"k"}.getStr()
        of "stop":
          sim.applyWallClockStop(int32(node{"tick"}.getInt(sim.tickCount)))
        of "intent":
          sim.pushFeedIntent(chat.message)
        of "register":
          let seat = node{"seat"}.getInt(-1)
          if seat >= 0 and seat < BodyCount:
            sim.seatPolicyKind[seat] = node{"kind"}.getStr()
        else:
          discard
    inc replay.chatIndex

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message = "Replay hash mismatch at tick " & $sim.tickCount &
      "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick FROM THE RECORDED COMMAND BYTES.
  ## Never steps past the last recorded hash: a `fault` episode's final tick is
  ## the one that raised, and re-running it in the browser would surface the
  ## guard as a viewer error rather than as the end of a partial replay.
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  replay.applyReplayEvents(sim)
  sim.step(replay.masks)
  replay.checkReplayHash(sim)

proc buildLullSpans*(beatTicks: seq[int],
                     startTick, maxTick: int): seq[array[2, int]] =
  ## Turns the ascending beat-tick list into the quiet spans between beats,
  ## keeping `LullLeadTicks` of context on both sides and dropping spans
  ## shorter than `MinLullTicks`: skipping a short breather is more jarring
  ## than watching it.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len: beatTicks[i]
      else: maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanLead(sim: SimServer): seq[int] =
  ## The momentum metric: the banked ROUND DIFFERENTIAL per bug (in
  ## milli-points) plus a second trace of who is holding the middle.
  for i in 0 ..< BodyCount:
    result.add int(sim.roundMicro[i] div 1000)

proc scanSeriesPoint(tick: int, lead: seq[int]): seq[int] =
  result = @[tick]
  result.add(lead)

proc scanComplete*(replay: ReplayPlayer): bool =
  replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(replay: var ReplayPlayer, initialSim: SimServer,
                     interval = ReplayKeyframeTicks) =
  ## Starts the whole-match precompute walk: seek keyframes, the round
  ## differential change-point series, the story beats and the beat ticks the
  ## lull map derives from.
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastLead = scanLead(scan.sim)
  replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, scan.lastLead))
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  ## Advances the precompute walk by up to `maxTicks` ticks; when it stops it
  ## derives the lull spans from whatever prefix it covered and marks the lead
  ## chrome ready. No-op once finished.
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except CatchableError as error:
      ## A malformed record would otherwise re-raise from this same tick on
      ## EVERY subsequent frame — the walk's cursor cannot advance past it.
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ", error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    let lead = scanLead(scan.sim)
    if lead != scan.lastLead:
      replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, lead))
      scan.lastLead = lead
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      ## The scrubber's up-front timeline. `contact`, `shove`, `stagger`,
      ## `rim_slip` and `turn_end` stay OUT: they fire dozens of times a round
      ## and would bury the beats.
      if event["k"].getStr() in BeatKinds:
        replay.beatEvents.add(event)
    for event in stepBeats:
      ## The LULL scan uses the SAME definition of a beat as the timeline. It
      ## used to take any kind outside ["contact","shove","rim_slip"], which let
      ## `turn_end` in — and `turn_end` fires every `turnTicks` (36) ticks,
      ## while a lull span needs a beat-free stretch of 341 ticks. So no span
      ## ever qualified, `lullSpans` was always empty, `state["lulls"]` was
      ## never emitted and the transport's skip-lulls control did nothing at all
      ## (r1 review N13).
      if event["k"].getStr() in BeatKinds:
        scan.beatTicks.add(scan.sim.tickCount)
        break
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, scan.lastLead))
  replay.lullSpans = buildLullSpans(scan.beatTicks, replay.replayStartTick(),
    scan.maxTick)
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int =
  ## Deterministic scan slice per presentation frame (frame-counted, no clock
  ## reads — machine speed must not change what any frame contains).
  96

proc buildReplayKeyframes*(replay: var ReplayPlayer, initialSim: SimServer,
                           interval = ReplayKeyframeTicks) =
  ## Runs the whole precompute walk synchronously (tests and offline tools).
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  ## Ticks playback may spend this frame: the chosen speed, boosted inside a
  ## lull while skip-lulls is on. At 1/2x a tick is spent only every OTHER
  ## frame — outside the lull boost, which is a skip and stays full pace.
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  if replay.speedIndex == ReplayHalfSpeedIndex:
    return (if replay.halfPhase: 1 else: 0)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(sim,
      replay.keyframes[replay.replayKeyframeIndex(tick)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc convergeSeek*(replay: var ReplayPlayer, sim: var SimServer): bool =
  ## Walks a pending seek up to `SeekTicksPerFrame` ticks closer to its target,
  ## so the first frame after a click already moves and no frame stalls.
  if replay.pendingSeekTick < 0:
    return false
  var stepped = 0
  while sim.tickCount < replay.pendingSeekTick and
      replay.hashIndex < replay.data.hashes.len and
      stepped < SeekTicksPerFrame:
    replay.stepReplay(sim)
    inc stepped
  if sim.tickCount >= replay.pendingSeekTick or
      replay.hashIndex >= replay.data.hashes.len:
    replay.pendingSeekTick = -1
  stepped > 0

proc beginSeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Starts a BOUNDED seek: land on the newest keyframe at or before `tick`
  ## (instant, which is what makes a scrubber click visible in the very next
  ## frame) and record the target; convergence happens a slice per frame.
  let target = clamp(tick, replay.replayStartTick(), replay.replayMaxTick())
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(sim,
      replay.keyframes[replay.replayKeyframeIndex(target)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  replay.pendingSeekTick = target

proc applyReplaySeek*(replay: var ReplayPlayer, sim: var SimServer,
                      tick: int) =
  replay.playing = false
  replay.beginSeek(sim, tick)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## One playback speed command. '5' selects the 1/2x replay speed
  ## (`ReplayHalfSpeedIndex`), which is also the floor '-' walks down to.
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, ReplayHalfSpeedIndex)
  of '5': speedIndex = ReplayHalfSpeedIndex
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc applyReplayCommand*(replay: var ReplayPlayer, sim: var SimServer,
                         command: char) =
  case command
  of ' ': replay.playing = not replay.playing
  of 'p': replay.playing = true
  of 'P': replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '5', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.beginSeek(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.beginSeek(sim, replay.replayMaxTick())
  of 'r': replay.looping = not replay.looping
  of 'f': replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.beginSeek(sim, sim.tickCount + ReplayFps * 5)
  else: discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(replay: var ReplayPlayer, sim: var SimServer,
                            onStep: proc () {.closure.},
                            onJump: proc () {.closure.}) =
  ## Advances one real-time playback frame. A LOOPING replay does NOT restart
  ## the moment playback stops: the final game-over frame (the endcard) holds
  ## for `ReplayEndHoldSeconds` of real time first.
  replay.halfPhase = not replay.halfPhase
  if replay.pendingSeekTick >= 0:
    ## A seek the viewer asked for OWNS the frame: converging it takes priority
    ## over the background walk and over playback.
    if replay.convergeSeek(sim):
      onJump()
    return
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc playbackSpeed*(speedIndex: int): int =
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the bytes SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the file.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"
