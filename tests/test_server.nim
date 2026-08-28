## 11. The websocket contract and the HTTP routes.
##
## The server is started IN PROCESS on a spare port with a scripted config, so
## every claim here is made against the real mummy handlers rather than against
## a paraphrase of them.

import std/[json, net, os, strformat, strutils, times]
import curly
import whisky
import bitworld/runtime
import bitworld/spriteprotocol
import bodies/[sim, intents]
import bodies/server as gameServer
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

const Port = 8793

let
  workDir = tempPath("server")
  configPath = workDir / "config.json"
  resultsPath = workDir / "results.json"
  replayPath = workDir / "episode.replay"
  eventsPath = workDir / "events.jsonl"

createDir(workDir)
writeFile(configPath, $(%*{
  "players": [{"name": "BUG-1"}, {"name": "BUG-2"}],
  "slots": [{"alias": "BUG-1"}, {"alias": "BUG-2"}],
  "num_agents": 2, "minPlayers": 2, "seed": 5104773,
  "maxTicks": 288, "maxRounds": 1, "roundsToClinch": 1, "maxGames": 1,
  "roundTicks": 216, "resetTicks": 36,
  "turnTicks": 36, "turnSpacingMs": 0, "wallClockBudgetSeconds": 120,
  "lobbyJoinTimeoutTicks": 480, "startWaitTicks": 24,
  "gameOverTicks": 24, "fastMode": true,
  "tokens": ["token-0", "token-1"]
}))

putEnv("COGAME_RESULTS_URI", "file://" & resultsPath)
putEnv("COGAME_SAVE_REPLAY_URI", "file://" & replayPath)
putEnv("COGAME_EVENTS_URI", "file://" & eventsPath)

var config = defaultGameConfig()
config.update(readFile(configPath))

type ServerArgs = object
  cfg: GameConfig
  runtime: RuntimeConfig
  savePath: string

var serverThread: Thread[ServerArgs]

proc serveProc(args: ServerArgs) {.thread.} =
  {.gcsafe.}:
    try:
      runServerLoop("127.0.0.1", Port, args.cfg, args.savePath, "", "",
        args.runtime)
    except CatchableError as error:
      echo "server loop ended: ", error.msg

var serverRuntime = RuntimeConfig(host: "127.0.0.1", port: Port,
  resultsUri: "file://" & resultsPath, replayUri: "file://" & replayPath)

createThread(serverThread, serveProc, ServerArgs(cfg: config,
  runtime: serverRuntime, savePath: workDir / "srv.replay"))

let pool = newCurlPool(2)

proc waitForHealth(): bool =
  for _ in 0 ..< 200:
    try:
      if pool.get(&"http://127.0.0.1:{Port}/healthz").code == 200:
        return true
    except CatchableError:
      discard
    sleep(100)
  false

check waitForHealth(), "the server never answered /healthz"

# --- /healthz and the client routes -----------------------------------
block:
  let health = pool.get(&"http://127.0.0.1:{Port}/healthz")
  check health.code == 200 and health.body == "healthy",
    &"/healthz answered {health.code} {health.body}"
  ## BOTH /client/ routes serve REAL pages and neither opens the player socket
  ## (the certifier probes them BEFORE starting the player pods).
  for route in ["/client/global", "/client/player", "/client/replay"]:
    let page = pool.get(&"http://127.0.0.1:{Port}{route}")
    check page.code == 200, &"{route} answered {page.code}"
    check page.body.contains("<html"), &"{route} did not serve an HTML page"
    check page.body.contains("BODIES_WIRE"),
      &"{route} did not splice the wire constants"
    check page.body.contains("window.ChromeCommon"),
      &"{route} did not splice chrome_common.js"

# --- a BAD TOKEN is refused 403, and the websocket is closed ----------
block:
  let bad = pool.get(&"http://127.0.0.1:{Port}/player?slot=0&token=bad")
  check bad.code == 403,
    &"a bad token got {bad.code} from /player, want 403 (cogame-flatland 0.1.1)"
  var opened = false
  try:
    let socket = newWebSocket(&"ws://127.0.0.1:{Port}/player?slot=0&token=bad")
    opened = true
    socket.close()
  except CatchableError:
    opened = false
  check not opened, "a bad-token player websocket was accepted"

# --- a viewer socket may not carry player credentials ----------------
block:
  let forbidden = pool.get(&"http://127.0.0.1:{Port}/global?slot=0")
  check forbidden.code == 403,
    &"/global with player credentials answered {forbidden.code}, want 403"

# --- the seats play a whole episode ----------------------------------
block:
  var sockets: seq[WebSocket]
  for seat in 0 ..< BodyCount:
    var socket: WebSocket = nil
    for _ in 0 ..< 40:
      try:
        socket = newWebSocket(
          &"ws://127.0.0.1:{Port}/player?slot={seat}&token=token-{seat}")
        break
      except CatchableError:
        sleep(100)
    check socket != nil, &"seat {seat} could not connect"
    if socket == nil:
      continue
    sockets.add socket
    ## The registration, plus a NON-registration chat which must be DROPPED,
    ## plus an input mask which must be IGNORED.
    socket.send(blobFromSpriteChat($(%*{
      "type": "register",
      "prompt": "",
      "scripted": (if seat == 0: "pusher" else: "anchor"),
      "policy": "test-seat-" & $seat
    })), BinaryMessage)
    socket.send(blobFromSpriteChat("just a chat line, not a registration"),
      BinaryMessage)
    socket.send(blobFromSpriteMask(0xFF'u8), BinaryMessage)

  ## Drive the frames until the game finishes.
  ## A BOUNDED receive: whisky's default blocks until a frame arrives, and the
  ## episode stops sending the moment it is over — which would burn the
  ## server's shutdown grace waiting on a socket that has nothing left to say.
  var frames = 0
  let deadline = epochTime() + 180.0
  while epochTime() < deadline and sockets.len > 0 and
      not fileExists(resultsPath):
    var alive: seq[WebSocket]
    for socket in sockets:
      if fileExists(resultsPath):
        alive.add socket
        continue
      try:
        let received = socket.receiveMessage(timeout = 250)
        if received.isSome:
          inc frames
          socket.send(blobFromSpriteReady(), BinaryMessage)
        alive.add socket
      except CatchableError:
        discard
    sockets = alive
  check frames > 60, &"the seats only received {frames} frames"
  for socket in sockets:
    try: socket.close() except CatchableError: discard

  ## /healthz and /global still answer AFTER the artifacts are written (the
  ## bounded shutdown grace, cogame-lantern 0.1.3).
  var wroteResults = false
  for _ in 0 ..< 300:
    if fileExists(resultsPath):
      wroteResults = true
      break
    sleep(100)
  check wroteResults, "the episode wrote no results.json"
  if wroteResults:
    ## The bounded shutdown grace: the runner pings /healthz and /global AFTER
    ## the player pods start, and a short episode can already have written its
    ## artifacts by then (cogame-lantern 0.1.3).
    var stillServing = false
    let latePool = newCurlPool(1)
    for _ in 0 ..< 20:
      try:
        if latePool.get(&"http://127.0.0.1:{Port}/healthz").code == 200:
          stillServing = true
          break
      except CatchableError:
        discard
      sleep(200)
    check stillServing,
      "/healthz stopped answering the moment the artifacts were written"
    try:
      let globalLate = latePool.get(&"http://127.0.0.1:{Port}/global")
      check globalLate.code == 200,
        "/global stopped answering after the artifacts were written"
    except CatchableError:
      echo "FAIL: /global stopped answering after the artifacts were written"
      inc failures
    let results = parseJson(readFile(resultsPath))
    check results["names"].len == BodyCount,
      "results.names is not one entry per seat"
    check results["reason"].getStr() in ["complete", "deadline", "fault"],
      "results.reason is outside its enum"
    check results["policyKinds"][0].getStr() == "scripted",
      "a scripted seat did not report policyKind `scripted`"
    ## A REGISTRATION IS NOT ECHOED into the replay chat stream as a shout, and
    ## a plain chat line from a player is dropped entirely.
    check fileExists(replayPath), "the episode wrote no replay"
    if fileExists(replayPath):
      let bytes = readFile(replayPath)
      check not bytes.contains("just a chat line"),
        "a non-registration chat from a player reached the replay"
      check bytes.contains("\"k\":\"register\""),
        "the replay carries no register record"
      check bytes.contains("test-seat-0"),
        "the register record did not carry the policy label"

  ## The replay-data route serves the recorded bytes — while the bounded
  ## shutdown grace is still running. Past it the process is gone by design, so
  ## a refused connection here is not a failure.
  try:
    let served = pool.get(&"http://127.0.0.1:{Port}/replay-data")
    check served.code in [200, 404], &"/replay-data answered {served.code}"
  except CatchableError:
    discard

## Let the server finish its bounded shutdown grace before this process tears
## its globals down: exiting underneath a live serve thread is a segfault, not
## a test result.
joinThread(serverThread)
removeDir(workDir)
if failures > 0:
  quit("test_server: " & $failures & " failure(s)", 1)
echo "test_server: ok"
## Exit WITHOUT running the module teardown: mummy and curly both keep shared
## allocations alive across threads, and tearing them down from an exiting main
## thread segfaults on a green run — which would read as a test failure.
quit(0)
