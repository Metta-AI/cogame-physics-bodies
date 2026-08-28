## The shared deterministic replay runtime: native and WASM hosts both drive
## playback through exactly these three procs, so a hosted replay and a local
## `--load-replay` tell the same story.
##
## Byte-identical to ctf's `src/ctf/replay_runtime.nim` apart from the imports
## and the chrome frame's argument list.

import std/json
import bitworld/spriteprotocol
import sim, global, broadcast, replays

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc initReplayRuntime*(data: ReplayData, mismatchQuit: bool,
                        gameEventLoggingEnabled = true): InitializedReplay =
  ## Constructs and starts replay playback from the RECORDED game config, so a
  ## constant this build happened to change can never alter an old replay.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  ## The whole-match precompute walk starts here and advances a bounded slice
  ## per presentation frame; only the short lobby walk to the first Playing
  ## tick — the spectator start — is paid up front.
  result.player.initReplayScan(result.sim)
  while result.sim.phase != Playing and
      result.sim.tickCount < result.player.replayMaxTick() and
      result.player.hashIndex < result.player.data.hashes.len and
      not result.player.hashValidationFailed:
    result.player.stepReplay(result.sim)
  if result.player.startTick < 0 and result.sim.phase == Playing:
    result.player.startTick = result.sim.gameStartTick
  result.player.seekReplay(result.sim, result.player.replayStartTick())
  result.player.playing = true
  result.tracker = initBroadcastTracker()
  result.tracker.resync(result.sim)

proc advanceReplayFrame*(replay: var ReplayPlayer, sim: var SimServer,
                         tracker: var BroadcastTracker,
                         seekTicks: openArray[int],
                         commands: openArray[char]): JsonNode =
  ## Applies viewer controls and advances one public presentation frame.
  var didSeek = false
  for seekTick in seekTicks:
    replay.applyReplaySeek(sim, seekTick)
    didSeek = true
  for command in commands:
    let tickBeforeCommand = sim.tickCount
    replay.applyReplayCommand(sim, command)
    if sim.tickCount != tickBeforeCommand:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    replay.cancelEndHold()

  let events = newJArray()
  let
    simPtr = sim.addr
    trackerPtr = tracker.addr
  replay.advanceReplayPlayback(
    sim,
    proc () = simPtr[].stepEvents(trackerPtr[], events),
    proc () = trackerPtr[].resync(simPtr[])
  )
  result = events

proc buildReplayViewerPacket*(sim: var SimServer, replay: ReplayPlayer,
                              state: GlobalViewerState,
                              nextState: var GlobalViewerState,
                              events: JsonNode): seq[uint8] =
  ## Builds the shared replay board + chrome packet for one viewer.
  result = sim.buildSpriteProtocolUpdates(state, nextState)
  if result.len == 0:
    return
  ## The lead chrome (momentum series, beat markers, lull spans) waits for the
  ## background precompute walk: it ships ONCE per viewer, so sending before
  ## the walk finishes would freeze a half-scanned timeline into the HUD. The
  ## client keys on presence, not frame number — late is fine.
  let sendLead = not state.momentumSent and replay.scanComplete
  result.addSprite(
    BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
    sim.buildStateJson(
      events,
      replay.playing,
      replay.replaySpeed(),
      replay.replayMaxTick(),
      replay.looping,
      true,
      replay.hashMismatchTick,
      (if sendLead: replay.leadSeries else: @[]),
      replay.replayStartTick(),
      replay.endHoldSecondsLeft(),
      replay.skipLulls,
      replay.skipLulls and replay.playing and
        replay.isLullTick(sim.tickCount),
      (if sendLead: replay.lullSpans else: @[]),
      (if sendLead: replay.beatEvents else: nil)
    )
  )
  if sendLead:
    nextState.momentumSent = true
