## The game server: mummy HTTP + websockets, the 24 Hz wall-clock-paced game
## loop, the decision turn, the recorded action log, and the artifact writes.
##
## This is ctf's `src/ctf/server.nim` with the five named edits of the design
## note:
##
## 1. INPUT SOURCE. Where ctf reads `appState.inputMasks` (the socket) into
##    `inputs[playerIndex]`, physics-bodies calls `control.driveCommand` for
##    both bodies and passes the command-byte array into `sim.step`. Player
##    sockets contribute NO input: any input mask arriving on one is discarded.
## 2. REPLAY INPUT WRITE. ctf's `writeInputFrameMasks` press/release wrapper is
##    DELETED — its `repeatedPressedMask` logic is button semantics and would
##    corrupt a value byte. We call `writeInputMaskChange` directly and let the
##    codec's own change-only guard do the rest.
## 3. TURN BOUNDARY. Immediately before stepping a tick where
##    `tick mod turnTicks == 0`, the loop runs `decide.turn`, which enforces the
##    inter-batch floor, issues the ONE parallel two-request batch, applies the
##    deadlines, installs the intents and writes the `intent`/`fallback`
##    records — all inside a monotonic `turnBudgetMs` bound.
## 4. WALL-CLOCK STOP. A `wallClockBudgetSeconds` check at the top of every loop
##    iteration writes ONE load-bearing `stop` record and forces
##    `deadline/wall_clock`, applied by the same proc on record and on playback
##    (cogame-particle-worlds 13c66d7).
## 5. SHUTDOWN GRACE. `/healthz` and `/global` keep answering for a bounded
##    ~20 s after the artifacts are written, then the process exits
##    (cogame-lantern 0.1.3: the episode runner pings `/global` with a 2 s
##    deadline AFTER the player pods start, and a short episode can already be
##    gone).

import std/[json, locks, monotimes, nativesockets, os, strutils, tables, times]
import bitworld/client as bitworldClient
import bitworld/runtime
import bitworld/spriteprotocol
import mummy
import sim, global, replays, broadcast, replay_runtime, events, wire_constants
import intents, control, baselines, decide

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    loadingReplayUri: string
    currentReplayUri: string
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    spritesOff: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    closedSockets: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig
    replayBytes: string

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  WallTextureHorizontalPath = "/client/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/client/art/walls/wall_v.jpg"
  BroadcastFontPath = "/client/font.ttf"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (sends 1009). We
    ## chunk outbound sprite packets under a margin below that.
  ShutdownGraceSeconds = 20

  ## The designed broadcast client, embedded at compile time: a single
  ## self-contained page (shared chrome + core JS inlined). Final in-page
  ## script order is fixed by the marker positions in the HTML.
  EmbeddedBroadcastReplayHtml = staticRead(
      "../../client/replay_broadcast.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()
  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")
  BroadcastFont = staticRead("../../data/font.ttf")
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/green_1.webp",
      staticRead("../../client/art/lockerroom/green_1.webp")),
    ("/client/art/lockerroom/green_2.webp",
      staticRead("../../client/art/lockerroom/green_2.webp")),
    ("/client/art/lockerroom/green_3.webp",
      staticRead("../../client/art/lockerroom/green_3.webp")),
    ("/client/art/lockerroom/green_5.webp",
      staticRead("../../client/art/lockerroom/green_5.webp")),
    ("/client/art/lockerroom/green_6.webp",
      staticRead("../../client/art/lockerroom/green_6.webp")),
    ("/client/art/lockerroom/blue_1.webp",
      staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("/client/art/lockerroom/blue_2.webp",
      staticRead("../../client/art/lockerroom/blue_2.webp")),
    ("/client/art/lockerroom/blue_3.webp",
      staticRead("../../client/art/lockerroom/blue_3.webp")),
    ("/client/art/lockerroom/blue_5.webp",
      staticRead("../../client/art/lockerroom/blue_5.webp")),
    ("/client/art/lockerroom/blue_6.webp",
      staticRead("../../client/art/lockerroom/blue_6.webp")),
    ("/client/art/lockerroom/yellow_1.webp",
      staticRead("../../client/art/lockerroom/yellow_1.webp")),
    ("/client/art/lockerroom/yellow_2.webp",
      staticRead("../../client/art/lockerroom/yellow_2.webp")),
    ("/client/art/lockerroom/yellow_3.webp",
      staticRead("../../client/art/lockerroom/yellow_3.webp")),
    ("/client/art/lockerroom/yellow_5.webp",
      staticRead("../../client/art/lockerroom/yellow_5.webp")),
    ("/client/art/lockerroom/yellow_6.webp",
      staticRead("../../client/art/lockerroom/yellow_6.webp")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/red_2.webp",
      staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/client/art/lockerroom/red_3.webp",
      staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/client/art/lockerroom/red_5.webp",
      staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/client/art/lockerroom/red_6.webp",
      staticRead("../../client/art/lockerroom/red_6.webp"))
  ]

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.spritesOff = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.closedSockets = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc disconnectWebSocket(websocket: WebSocket) =
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc nextAnonymousPlayerIdentity(): string =
  {.gcsafe.}:
    withLock appState.lock:
      result = "Player" & $appState.nextAnonymousPlayer
      inc appState.nextAnonymousPlayer

proc playerSlotOf(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerTokenOf(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
  result = nextAnonymousPlayerIdentity()

proc respondForbiddenWebSocket(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc hasPlayerCredentialParams(request: Request): bool =
  request.queryParams.getOrDefault("name", "").strip().len > 0 or
    request.queryParams.getOrDefault("slot", "").strip().len > 0 or
    request.queryParams.getOrDefault("token", "").strip().len > 0

proc registerPlayerWebSocket(websocket: WebSocket, identity: string,
                             slot: int, token: string) =
  appState.globalViewers.del(websocket)
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.playerAddresses[websocket] = identity
  appState.playerSlots[websocket] = slot
  appState.playerTokens[websocket] = token
  appState.playerIndices[websocket] = 0x7fffffff
  appState.playerReady[websocket] = false

proc registerGlobalWebSocket(websocket: WebSocket) =
  appState.playerViewers.del(websocket)
  appState.playerIndices.del(websocket)
  appState.globalViewers[websocket] = initGlobalViewerState()

proc isPlayerWebSocket(websocket: WebSocket): bool =
  websocket in appState.playerViewers and
    websocket notin appState.globalViewers

proc removeWebSocketState(websocket: WebSocket): int =
  result = -1
  if websocket in appState.playerIndices:
    result = appState.playerIndices[websocket]
    appState.playerIndices.del(websocket)
  appState.globalViewers.del(websocket)
  appState.playerViewers.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  appState.playerReady.del(websocket)
  appState.spritesOff.del(websocket)

proc isPlayerReadyPacket*(message: string): bool =
  ## The one-byte Sprite v1 player-ready packet.
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc isSpritesOffPacket*(message: string): bool =
  ## The one-byte Sprite v1 sprites-off packet (0x87). The pinned bitworld
  ## predates the packet, so the id is declared here rather than imported.
  message.len == 1 and message[0].uint8 == 0x87'u8

proc parseRegistration*(text: string):
    tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"pusher"|null,"policy":"…"}
  ## Anything that is not that object is not a registration.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc replayServerModeEnabled(): bool =
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayServerMode

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    ## The bytes this episode recorded, for anything that wants the replay
    ## straight off the game container.
    var bytes = ""
    {.gcsafe.}:
      withLock appState.lock:
        bytes = appState.replayBytes
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    request.respond((if bytes.len > 0: 200 else: 404), headers, bytes)
  elif request.path == WebSocketPath and request.httpMethod == "GET":
    let
      slot = request.playerSlotOf()
      token = request.playerTokenOf()
      identity = request.playerIdentity(slot, token)
    ## A player websocket whose token does not match the seat is CLOSED: the
    ## certifier probes `?slot=0&token=bad` and a server that accepts it fails
    ## cert `smoke-episode` (cogame-flatland 0.1.1).
    var allowed = false
    {.gcsafe.}:
      withLock appState.lock:
        allowed = appState.config.playerJoinAllowed(identity, slot, token)
    if not allowed:
      request.respondForbiddenWebSocket(
        "Player credentials do not match configured slot " & $slot & ".")
      return
    if not request.isWebSocketUpgrade():
      ## The certifier probes this route with a plain GET too; answering the
      ## catch-all 200 there would say the credentials were fine.
      var headers: HttpHeaders
      headers["Content-Type"] = "text/plain; charset=utf-8"
      headers["Cache-Control"] = "no-cache"
      request.respond(200, headers, "physics-bodies player socket\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerPlayerWebSocket(identity, slot, token)
    echo "player connected: ", identity
  elif request.path in [GlobalWebSocketPath, ReplayWebSocketPath] and
      request.httpMethod == "GET":
    if request.hasPlayerCredentialParams():
      request.respondForbiddenWebSocket(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    if not request.isWebSocketUpgrade():
      var headers: HttpHeaders
      headers["Content-Type"] = "text/plain; charset=utf-8"
      headers["Cache-Control"] = "no-cache"
      request.respond(200, headers, "physics-bodies spectator socket\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path in [WallTextureHorizontalPath, WallTextureVerticalPath] and
      request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    if request.path == WallTextureHorizontalPath:
      request.respond(200, headers, WallTextureHorizontal)
    else:
      request.respond(200, headers, WallTextureVertical)
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.httpMethod == "GET" and (block:
      var hit = false
      for (path, _) in LockerRoomAssets:
        if request.path == path:
          hit = true
          break
      hit):
    var headers: HttpHeaders
    headers["Content-Type"] =
      if request.path.endsWith(".webp"): "image/webp" else: "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        request.respond(200, headers, art)
        break
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      bitworldClient.GlobalClientRoute,
      bitworldClient.CoworldGlobalClientRoute,
      bitworldClient.PlayerClientRoute,
      bitworldClient.CoworldPlayerClientRoute
    ] and request.httpMethod == "GET":
    ## BOTH `/client/` routes serve REAL pages, registered BEFORE any catch-all
    ## asset route, and neither opens the player socket (cogame-lantern 0.1.1:
    ## the certifier probes them before starting the player pods).
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, EmbeddedBroadcastReplayHtml)
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "physics-bodies server")

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    ## NOTHING ELSE IN THIS HANDLER IS GUARDED BY MESSAGE KIND. A
    ## `kind != TextMessage` guard would drop the player's binary registration
    ## frames, and losing the Ping -> Pong branch is a cert
    ## `game_contract_violation` (seen twice: lux-ai 0.1.0, snake-royale 0.1.0).
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif message.data.isSpritesOffPacket():
            appState.spritesOff[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers:
            var chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data, chatText)
            ## A seat's chat is its REGISTRATION and nothing else. Anything
            ## else is dropped HERE rather than in the loop, so a later chat
            ## line can never overwrite a registration that has not been
            ## consumed yet — cogs shout, seats do not.
            if chatText.len > 0 and parseRegistration(chatText).ok:
              appState.chatMessages[websocket] = chatText
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        let newlyClosed = markSocketClosed(websocket)
        if newlyClosed and websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

type FrameAdvance = enum
  LateFrame, SkippedFrame, WaitedFrame

proc allPlayersReady(sockets: openArray[WebSocket],
                     playerIndices: openArray[int], seats: int): bool =
  var active = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= playerIndices.len or playerIndices[i] < 0 or
            playerIndices[i] >= seats:
          continue
        inc active
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  active > 0

proc resetPlayerReady(sockets: openArray[WebSocket],
                      playerIndices: openArray[int], seats: int) =
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i < playerIndices.len and playerIndices[i] >= 0 and
            playerIndices[i] < seats and websocket in appState.playerReady:
          appState.playerReady[websocket] = false

proc runFrameLimiter(previousTick: var MonoTime, fastMode: bool,
                     sockets: openArray[WebSocket],
                     playerIndices: openArray[int],
                     seats: int): FrameAdvance =
  ## `fastMode` advances the sim as soon as every player container has
  ## acknowledged the frame, so SIM TIME is not charged against the wall
  ## clock — the decision turns are the pacing.
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  var slept = false
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      result = if slept: WaitedFrame else: LateFrame
      break
    if fastMode and sockets.allPlayersReady(playerIndices, seats):
      result = SkippedFrame
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
    slept = true
  previousTick = getMonoTime()

proc declarePlayerFailure(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for, so a lobby no-show is charged to the seat that caused it
  ## instead of poisoning the whole episode unattributed. Best-effort: outside
  ## the platform (env unset) this is a no-op.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc runServerLoop*(host: string = sim.DefaultHost,
                    port: int = sim.DefaultPort,
                    initialConfig = defaultGameConfig(),
                    saveReplayPath = "", loadReplayPath = "",
                    saveScoresPath = "",
                    runtimeConfig = RuntimeConfig()) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        ## A bad or version-mismatched replay must not kill the server: the
        ## viewer would see a dead socket with no explanation.
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initializedReplay =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: move(initializedReplay.config) else: initialConfig
  var
    sim =
      if replayLoaded: move(initializedReplay.sim) else: initSimServer(config)
    replayPlayer =
      if replayLoaded: move(initializedReplay.player) else: ReplayPlayer()
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()
    replayWriter = openReplayWriter(saveReplayPath,
      config.configJson(sim.perm))
  defer: replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayLoaded
  appState.config = config

  ## Tier-2 event sink. Off unless the platform configured a destination.
  ## file:// ONLY, and it fails loudly otherwise rather than silently dropping
  ## the stream: the dispatcher writes this as a workdir path and the runner
  ## uploads the file afterwards.
  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri)
  let metricsPath = block:
    let uri = getEnv("COGAME_METRICS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_METRICS_URI must be a file:// path, got: " & uri)

  var collectedEvents: seq[SimEvent] = @[]
  sim.collectEvents = eventsPath.len > 0

  block:
    ## Bake the board plate BEFORE the listener opens: a viewer's first-message
    ## clock starts at its successful connect (the certifier allows only
    ## seconds), so nothing may be accepted until every frame the loop will
    ## ever build can be assembled instantly.
    let warmStart = getMonoTime()
    sim.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    engine = if replayLoaded: DecisionEngine() else: initDecisionEngine(sim)
    lastTick = getMonoTime()
    episodeStart = getMonoTime()
    deadlineHit = false
    forceStart = false
    lastTurnKey = -1
    liveSpeedIndex = 0
    quitAfterFrame = false
    cmds = newSeq[uint8](BodyCount)
    reportedNoShow = false

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]

    ## EDIT 4 — the engine's own hard stop, checked before anything else this
    ## iteration. `wallClockBudgetSeconds` is 55 % of the assumed 1200 s
    ## `episodeTimeoutSeconds`, so the episode always settles and scores itself
    ## rather than being silently discarded for overrunning.
    if not replayLoaded and not deadlineHit and sim.phase != GameOver and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      deadlineHit = true
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode from the state at this tick"
      replayWriter.writeChat(tickTime(sim.tickCount), 0,
        stopRecord(sim.tickCount, "wall_clock"))
      sim.applyWallClockStop(int32(sim.tickCount))
      ## One more (GameOver, no-op) tick so the stop lands INSIDE the hash
      ## chain and playback can render the endcard rather than stopping short.
      sim.step(cmds)
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          ## A seat that drops does NOT remove its bug: the bodies are fixed
          ## for the whole episode, the seat's intent source degrades to
          ## `pusher`, and it revives on reconnect.
          let index = removeWebSocketState(websocket)
          if not replayLoaded and index >= 0 and index < sim.players.len:
            replayWriter.writeLeave(tickTime(sim.tickCount), index)
            sim.removePlayerAt(index)
        appState.closedSockets.setLen(0)

        if not replayLoaded and sim.lobbyJoinTimedOut() and
            not reportedNoShow:
          ## A seat that never connects does NOT end the episode: report the
          ## no-show (lowest missing slot only), then play on — that bug runs
          ## the published `pusher` baseline for the whole match.
          reportedNoShow = true
          forceStart = true
          let stuckSlot = sim.nextPlayerSlot()
          declarePlayerFailure(stuckSlot,
            "player slot " & $stuckSlot & " never joined the lobby within " &
              $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
              $(config.lobbyJoinTimeoutTicks div TargetFps) &
              "s); its bug plays the pusher baseline")
          echo "physics-bodies: seat ", stuckSlot,
            " never registered; driving ", alias(sim.bodyOfSeat(stuckSlot)),
            " with pusher"

        if not replayLoaded:
          ## Admit pending joins in slot order.
          var pending: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket() and
                appState.playerIndices[websocket] == 0x7fffffff:
              pending.add websocket
          for websocket in pending:
            let
              address = appState.playerAddresses.getOrDefault(websocket,
                "unknown")
              slot = appState.playerSlots.getOrDefault(websocket, -1)
              token = appState.playerTokens.getOrDefault(websocket, "")
            if sim.phase != Lobby or not sim.canAddPlayer():
              appState.playerIndices[websocket] = -1
              continue
            try:
              let index = sim.addPlayer(address, slot, token)
              appState.playerIndices[websocket] = index
              replayWriter.writeJoin(tickTime(sim.tickCount), index, address,
                slot, token)
              echo "seat ", index, " joined: ", address
            except BodiesError as error:
              echo "join refused: ", error.msg
              appState.playerIndices[websocket] = -1

        for websocket, playerIndex in appState.playerIndices.pairs:
          if not websocket.isPlayerWebSocket():
            continue
          sockets.add websocket
          playerIndices.add playerIndex
          playerViewerStates.add appState.playerViewers[websocket]

        if not replayLoaded:
          ## Registrations that cannot be applied YET are HELD, not dropped.
          ## A seat's first registration can arrive before its player index
          ## exists (the lobby sends frames to a socket before it is admitted),
          ## and clearing the table then discarded them for good — the champion
          ## played the scripted baseline for the whole episode with no
          ## `register` record at all.
          var held: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(websocket, -1)
            let registration = parseRegistration(chatText)
            if playerIndex < 0 or playerIndex >= BodyCount:
              if websocket.isPlayerWebSocket() and registration.ok:
                held.add((websocket, chatText))
              continue
            if not registration.ok:
              ## A seat's chat is its REGISTRATION and nothing else: any other
              ## text from a player socket is dropped, never applied and never
              ## written to the replay.
              continue
            var policy = engine.seats[playerIndex]
            let firstRegistration = not policy.registered
            policy.registered = true
            policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
            policy.isLlm = policy.prompt.len > 0
            policy.baseline = parseBaseline(registration.scripted)
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: "prompt"
              else: $policy.baseline
            engine.seats[playerIndex] = policy
            sim.seatPolicyKind[playerIndex] = engine.policyKind(playerIndex)
            if firstRegistration:
              ## One `register` record and one log line per seat: the seat
              ## re-sends its registration for the first ~10 s of frames.
              replayWriter.writeChat(tickTime(sim.tickCount), playerIndex,
                registerRecord(playerIndex, sim.bodyOfSeat(playerIndex),
                  policy.label, engine.policyKind(playerIndex),
                  $policy.baseline))
              echo "seat ", playerIndex, " registered: kind=",
                engine.policyKind(playerIndex), " baseline=",
                $policy.baseline
          appState.chatMessages.clear()
          for (websocket, chatText) in held:
            appState.chatMessages[websocket] = chatText

        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add websocket
          globalStates.add state
          if state.replaySeekTick >= 0:
            replaySeekTicks.add state.replaySeekTick
          for command in state.replayCommands:
            replayCommands.add command
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1

    ## Force the match to start once every seat is in (or the lobby budget
    ## expired and the no-show has been reported).
    if not replayLoaded and sim.phase == Lobby and
        (sim.players.len >= sim.seatCount() or forceStart) and
        sim.players.len + (if forceStart: 1 else: 0) > 0:
      if sim.lobbyTicks < config.startWaitTicks and forceStart:
        sim.lobbyTicks = config.startWaitTicks

    var frameEvents = newJArray()
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(sim, broadcastTracker,
        replaySeekTicks, replayCommands)
    elif not quitAfterFrame:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      for _ in 0 ..< playbackSpeed(liveSpeedIndex):
        ## EDIT 3 — the decision turn, immediately before the tick that starts
        ## it. This is the determinism boundary: the controller and the LLM live
        ## on THIS side of it, and only the bytes below are recorded, so the
        ## wasm viewer re-derives the whole match without running either.
        if sim.phase == Playing:
          let
            elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
            turnTicks = max(1, config.turnTicks)
            turnIndex = sim.tickCount div turnTicks
          if sim.tickCount mod turnTicks == 0 and turnIndex != lastTurnKey:
            lastTurnKey = turnIndex
            let records = engine.turn(sim, turnIndex, elapsedSeconds)
            for record in records:
              replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
            for seat in 0 ..< sim.seatCount():
              if not engine.haveIntent[seat]:
                continue
              let intent = engine.intents[seat]
              case intent.source
              of isLlm: inc sim.llmTurns[seat]
              of isFallback: inc sim.fallbackTurns[seat]
              of isScripted: discard
              let record = boundedIntentRecord(intent, turnIndex, seat,
                sim.bodyOfSeat(seat))
              replayWriter.writeChat(tickTime(sim.tickCount), seat, record)
              sim.pushFeedIntent(record)
              sim.emitEvent(Intent, source = sim.bodyOfSeat(seat),
                detail = $intent.source, amount = turnIndex,
                content = intent.note)

        ## EDIT 1 + 2 — compile ONE command byte per BODY, in index order, and
        ## write it straight into the action log.
        for i in 0 ..< BodyCount:
          let
            intent = engine.intentForBody(sim, i)
            cmd = driveCommand(engine.ctl, sim, i, intent, sim.tickCount)
            row = sim.inputIndexOfBody(i)
          if row >= 0 and row < cmds.len:
            cmds[row] = cmd
          replayWriter.writeInputMaskChange(tickTime(sim.tickCount), row, cmd)

        var faultRule = ""
        try:
          sim.step(cmds)
        except SimGuardError as guard:
          echo "physics-bodies: SIM GUARD tripped at tick ", sim.tickCount,
            ": ", guard.msg
          faultRule = EndRuleSimFault
        except CatchableError as error:
          echo "physics-bodies: HOST ERROR at tick ", sim.tickCount, ": ",
            error.msg
          faultRule = EndRuleHostError
        if faultRule.len > 0:
          ## A tripped invariant is NOT a silent non-zero exit: the episode
          ## ends `fault/<rule>` here and the artifact block below still writes
          ## the partial replay, the results and the events.
          sim.endReason = ReasonFault
          sim.endRule = faultRule
          sim.phase = GameOver
          quitAfterFrame = true
          break
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
        if sim.collectEvents:
          for event in sim.events:
            collectedEvents.add event
          sim.events.setLen(0)
        if sim.phase == GameOver:
          quitAfterFrame = true
          break

    if not replayLoaded and config.fastMode:
      sockets.resetPlayerReady(playerIndices, sim.seatCount())

    ## Per-seat frames. Board labels carry only BUG-1 / BUG-2:
    ## `showPlayerLabels` is forced false on the player stream.
    var spritesOffFlags = newSeq[bool](sockets.len)
    {.gcsafe.}:
      withLock appState.lock:
        for i in 0 ..< sockets.len:
          spritesOffFlags[i] =
            appState.spritesOff.getOrDefault(sockets[i], false)
    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i], playerViewerStates[i], nextState,
        spritesOff = spritesOffFlags[i])
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
      let wirePacket = dedupObjectPlacements(
        (if spritesOffFlags[i]: framePacket.stripSpritePixels()
         else: framePacket),
        nextState.sentPlacements)
      try:
        if wirePacket.len == 0:
          ## One binary message per tick is the frame contract — clients count
          ## messages to advance. An all-deduped frame still ships, as an
          ## empty message.
          sockets[i].send("", BinaryMessage)
        for chunk in chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(sockets[i])

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      var packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(replayPlayer, globalStates[i], nextState,
            frameEvents)
        else:
          block:
            var board = sim.buildSpriteProtocolUpdates(globalStates[i],
              nextState)
            sim.stepEvents(broadcastTracker, frameEvents)
            board.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
              sim.buildStateJson(frameEvents, true,
                playbackSpeed(liveSpeedIndex), sim.effectiveMaxTicks(),
                false, false, -1))
            board
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              ## The websocket thread keeps writing viewer INPUT into this
              ## entry while the frame was being built from an earlier
              ## snapshot; blindly storing nextState would erase any input that
              ## arrived in between.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if quitAfterFrame:
      ## The `result` control record: the full results document, written once
      ## into the replay chat stream at episode end, so the bytes are
      ## SELF-SUFFICIENT. Never applied as a shout at playback (a leading '{'
      ## marks a control record), so the hash chain is untouched.
      replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
      for entry in sim.roundLog:
        replayWriter.writeChat(tickTime(sim.tickCount), 0,
          roundRecord(int(entry.round), int(entry.winner), $entry.reason,
            int(entry.ticks), entry.knockdowns))
      if saveReplayPath.len > 0:
        echo "Writing replay file: ", saveReplayPath
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        let bytes = readFile(saveReplayPath)
        echo "Replay written: ", saveReplayPath, " (", bytes.len, " bytes)"
        {.gcsafe.}:
          withLock appState.lock:
            appState.replayBytes = bytes
        runtimeConfig.writeReplay(bytes)
      if eventsPath.len > 0:
        ## Always written when a sink is configured, even with zero events: the
        ## summary row is how a reader tells "this match had none" from "the
        ## upload never happened".
        writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
        echo "Events written: ", eventsPath, " (", collectedEvents.len,
          " events)"
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults(sim.playerResultsJson() & "\n")
      elif saveScoresPath.len > 0:
        writeFile(saveScoresPath, sim.playerResultsJson() & "\n")
        echo "Scores written: ", saveScoresPath
      if metricsPath.len > 0:
        writeFile(metricsPath,
          $(%*{"ticks": sim.tickCount, "rounds": sim.roundLog.len}) & "\n")
      echo "physics-bodies: episode over — ", sim.endReason, "/", sim.endRule,
        " rounds ", sim.roundsWon[0], "-", sim.roundsWon[1], " at tick ",
        sim.tickCount
      ## EDIT 5 — bounded shutdown grace.
      let graceUntil =
        getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
      while getMonoTime() < graceUntil:
        sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    discard runFrameLimiter(lastTick,
      not replayLoaded and config.fastMode and sim.phase != Lobby,
      sockets, playerIndices, sim.seatCount())
