## Decision turns against a fake ordinary player batch.

import std/[json, locks, monotimes, options, os, sequtils, strformat, strutils, times]
import mummy
from whisky import nil
import bitworld/runtime
import bitworld/spriteprotocol
import bodies/[sim, intents, control, baselines, decide, replays]
import bodies/server as gameServer
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

var
  fakeLock: Lock
  batches: seq[seq[BatchCall]]
  fakeDelayMs = 0
  fakeCause = ""
  fakeAction = """{"stance":"lift","aggression":9,"say":"under it","note":"fake"}"""
  epoch = getMonoTime()

initLock(fakeLock)

proc fakeBatch(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
    {.gcsafe.} =
  var delay: int
  var cause, action: string
  {.gcsafe.}:
    withLock fakeLock:
      delay = fakeDelayMs
      cause = fakeCause
      action = fakeAction
      batches.add(calls)
  sleep(min(delay, timeoutSeconds * 1000))
  result = newSeq[BatchReply](calls.len)
  for reply in result.mitems:
    if delay > timeoutSeconds * 1000:
      reply.cause = "timeout"
      reply.error = "player response timed out"
    elif cause.len > 0:
      reply.cause = cause
      reply.error = "player returned " & cause
    else:
      reply.ok = true
      reply.action = action

proc freshEngine(sim: SimServer, prompts = true): DecisionEngine =
  result = initDecisionEngine(sim)
  result.batch = fakeBatch
  for seat in 0 ..< BodyCount:
    result.seats[seat].registered = true
    result.seats[seat].isExternal = prompts
    result.seats[seat].label = "fake"

type GameServerArgs = object
  cfg: GameConfig
  runtime: RuntimeConfig
  port: int

var
  gameThread: Thread[GameServerArgs]
  gameThread2: Thread[GameServerArgs]

proc gameServeProc(args: GameServerArgs) {.thread.} =
  ## The REAL game server loop, in process, so the no-show declaration below is
  ## made against the actual lobby path rather than a paraphrase of it.
  {.gcsafe.}:
    try:
      runServerLoop("127.0.0.1", args.port, args.cfg, "", "", "",
        args.runtime)
    except CatchableError as error:
      echo "game server loop ended: ", error.msg

proc playingSim(): SimServer =
  var cfg = defaultMatchConfig()
  cfg.attempt1Ms = 2000
  cfg.retryMs = 2000
  cfg.turnBudgetMs = 4000
  cfg.turnSpacingMs = 0
  result = initSimServer(cfg)
  result.gameEventLoggingEnabled = false
  result.phase = Playing
  for seat in 0 ..< BodyCount:
    discard result.addPlayer("seat-" & $seat, seat, "")

# --- one shared batch carries both seat-local views --------------------
block:
  withLock fakeLock:
    batches.setLen(0)
    fakeDelayMs = 0
    fakeCause = ""
  var sim = playingSim()
  var engine = freshEngine(sim)
  discard engine.turn(sim, 0, 0)
  var captured: seq[seq[BatchCall]]
  withLock fakeLock:
    captured = batches
  check captured.len == 1 and captured[0].len == 2,
    "one turn did not submit both seats in one player batch"
  if captured.len == 1 and captured[0].len == 2:
    check captured[0][0].seat == 0 and captured[0][1].seat == 1,
      "batch seats were not distinct"
    check captured[0][0].view != captured[0][1].view,
      "both seats got the same private view"
  for seat in 0 ..< BodyCount:
    check engine.haveIntent[seat], &"seat {seat} got no intent"
    check engine.intents[seat].source == isLlm,
      &"seat {seat} did not record an external intent"
    check engine.intents[seat].stance == stanceLift,
      "player order was not parsed into the intent"

# --- consecutive batches respect the rate floor ------------------------
block:
  withLock fakeLock:
    batches.setLen(0)
  var sim = playingSim()
  sim.config.turnSpacingMs = 400
  var engine = freshEngine(sim)
  let started = getMonoTime()
  discard engine.turn(sim, 0, 0)
  discard engine.turn(sim, 1, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  check elapsed >= 400,
    &"two batches were {elapsed} ms apart, want at least 400"

# --- a hung player gets a bounded fallback -----------------------------
block:
  withLock fakeLock:
    batches.setLen(0)
    fakeDelayMs = 6000
  var sim = playingSim()
  var engine = freshEngine(sim)
  let started = getMonoTime()
  let records = engine.turn(sim, 0, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  check elapsed <= int64(sim.config.turnBudgetMs) + 1500,
    &"hung player held turn for {elapsed} ms"
  for seat in 0 ..< BodyCount:
    check engine.haveIntent[seat] and engine.intents[seat].source == isFallback,
      &"seat {seat} had no fallback intent"
  check records.anyIt(parseJson(it){"k"}.getStr() == "fallback"),
    "hung player wrote no fallback record"
  withLock fakeLock:
    fakeDelayMs = 0

# --- provider causes are player data; throttle skips retry -------------
block:
  withLock fakeLock:
    batches.setLen(0)
    fakeCause = "throttled"
  var sim = playingSim()
  var engine = freshEngine(sim)
  let records = engine.turn(sim, 0, 0)
  var captured: seq[seq[BatchCall]]
  withLock fakeLock:
    captured = batches
    fakeCause = ""
  check captured.len == 1, "throttled players were retried"
  check records.anyIt(parseJson(it){"cause"}.getStr() == "throttled"),
    "player throttle was not named in fallback record"

# --- the BUDGET GUARD switches to scripted and still ends complete/* ---
block:
  var sim = playingSim()
  sim.config.wallClockBudgetSeconds = 30
  var engine = freshEngine(sim)
  ## Elapsed is already past the point where two more turns would fit.
  let records = engine.turn(sim, 0, 25)
  check engine.externalOff, "the budget guard did not fire"
  var sawGuard = false
  for record in records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      sawGuard = true
  check sawGuard, "the budget guard wrote no `budget_guard` record"
  ## And with the LLM off the whole episode still finishes on the scripted
  ## layer, ending complete/* rather than deadline.
  var cfg = defaultMatchConfig()
  let episode = runEpisode(cfg)
  check episode.sim.endReason == ReasonComplete,
    &"a scripted episode ended {episode.sim.endReason}, want complete"

# --- the WALL-CLOCK STOP: deadline/wall_clock, and the record ---------
block:
  var cfg = certConfig()
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  sim.roundTick = 100
  let record = stopRecord(sim.tickCount, "wall_clock")
  sim.applyWallClockStop(int32(sim.tickCount))
  check sim.endReason == ReasonDeadline and sim.endRule == EndRuleWallClock,
    &"the wall-clock stop ended {sim.endReason}/{sim.endRule}"
  check sim.phase == GameOver, "the wall-clock stop did not end the episode"
  check sim.roundLog.len == 1 and sim.roundLog[^1].reason == roundDraw,
    "the round in progress was not banked as a DRAW at the stop"
  let node = parseJson(record)
  check node{"k"}.getStr() == "stop" and node{"cause"}.getStr() == "wall_clock",
    "the `stop` record is malformed"

# --- a tripped invariant is fault/sim_fault, not a silent exit --------
block:
  var cfg = defaultMatchConfig()
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  ## Step 8's arena clamp runs BEFORE the guard, so a torso cannot survive a
  ## whole tick outside the box — which is the point. The guard is asserted
  ## directly, on each of the states it exists to catch.
  var raised = 0
  sim.bodies[0].px = ArenaW + 1_000_000
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].px = RingCentreX
  sim.bodies[0].vx = MaxBodySpeedHard + 50_000
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].vx = 0
  sim.bodies[0].hMilli = 40_000
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].hMilli = 0
  sim.bodies[0].tipMilli = TipDown + 1
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].tipMilli = 0
  sim.bodies[0].groundedCount = 9
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].groundedCount = 4
  sim.roundTick = int32(sim.config.roundTicks + 3)
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.roundTick = 0
  check raised == 6,
    &"only {raised} of 6 invariant violations tripped the step-12 guard"
  sim.endReason = ReasonFault
  sim.endRule = EndRuleSimFault
  sim.phase = GameOver
  let results = parseJson(sim.playerResultsJson())
  check results["reason"].getStr() == "fault" and
    results["endRule"].getStr() == "sim_fault",
    "a faulted episode did not report fault/sim_fault"

# --- a seat with NO intent is driven by `pusher`, never left idle -----
block:
  var sim = playingSim()
  var engine = initDecisionEngine(sim)
  for i in 0 ..< BodyCount:
    let intent = engine.intentForBody(sim, i)
    check intent.stance in [stanceCharge, stanceBrace, stanceLift,
      stanceRetreat, stanceCircle, stanceCentre],
      "a bug with no registered seat got no usable intent"
  ## And a seat that DROPS keeps playing: removing the roster entry must not
  ## stop `intentForBody` returning an order for its bug.
  sim.removePlayerAt(1)
  for i in 0 ..< BodyCount:
    discard engine.intentForBody(sim, i)

# --- registrations are parsed, and a non-registration chat is dropped --
block:
  let ok = gameServer.parseRegistration(
    """{"type":"register","kind":"external","scripted":null,"policy":"champ"}""")
  check ok.ok and ok.kind == "external" and ok.policy == "champ" and
    ok.scripted.len == 0,
    "a valid registration did not parse"
  check not gameServer.parseRegistration("hello").ok,
    "a plain chat line was accepted as a registration"
  check not gameServer.parseRegistration("""{"type":"shout","text":"hi"}""").ok,
    "a non-register JSON object was accepted as a registration"

# --- a NEVER-CONNECTING seat: declared, logged, match still played ----
block:
  ## §End conditions and §Tests 7. Seat 1 never connects. The lobby budget
  ## expires, the no-show is declared to COGAME_PLAYER_FAILURE_URI, its bug is
  ## driven by `pusher`, and the match plays to a NORMAL ending. Before r1
  ## review N2 the round never started at all — `startRound` was gated on
  ## `players.len >= minPlayers`, so a one-seat episode sat in the lobby until
  ## the 660 s wall-clock stop and scored 0-0 with `rounds: 0`.
  let
    workDir = tempPath("engine-noshow")
    failurePath = workDir / "player-failure.json"
    resultsPath = workDir / "noshow-results.json"
  createDir(workDir)
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & failurePath)
  var cfg = defaultGameConfig()
  cfg.seed = 5104773
  cfg.players = @[PlayerConfig(name: "BUG-1"), PlayerConfig(name: "BUG-2")]
  cfg.maxGames = 1
  cfg.maxRounds = 1
  cfg.roundsToClinch = 1
  ## The lobby is charged against maxTicks too, so leave room for it: the round
  ## starts at tick 47 and its clock ends at 95, inside the 120-tick episode.
  cfg.roundTicks = 48
  cfg.resetTicks = 12
  cfg.maxTicks = 120
  cfg.turnTicks = 24
  cfg.turnSpacingMs = 0
  cfg.wallClockBudgetSeconds = 120
  cfg.lobbyJoinTimeoutTicks = 48       ## 2 s of lobby, not 30
  cfg.startWaitTicks = 12
  cfg.gameOverTicks = 12
  cfg.fastMode = true
  createThread(gameThread, gameServeProc, GameServerArgs(cfg: cfg, port: 8794,
    runtime: RuntimeConfig(host: "127.0.0.1", port: 8794,
      resultsUri: "file://" & resultsPath)))

  ## ONE seat joins. The other never does.
  var socket: whisky.WebSocket = nil
  for _ in 0 ..< 60:
    try:
      socket = whisky.newWebSocket("ws://127.0.0.1:8794/player?slot=0")
      break
    except CatchableError:
      sleep(100)
  check socket != nil, "seat 0 could not connect to the in-process server"
  if socket != nil:
    whisky.send(socket, blobFromSpriteChat($(%*{
      "type": "register", "kind": "scripted", "scripted": "pusher",
      "policy": "test-noshow-0"})), whisky.BinaryMessage)
    ## Ack every frame so `fastMode` advances on the seat rather than on the
    ## 24 fps floor; bounded receive, and bounded overall.
    let deadline = epochTime() + 120.0
    while epochTime() < deadline and not fileExists(resultsPath):
      try:
        if whisky.receiveMessage(socket, timeout = 250).isSome:
          whisky.send(socket, blobFromSpriteReady(), whisky.BinaryMessage)
      except CatchableError:
        break
    try: whisky.close(socket) except CatchableError: discard
  joinThread(gameThread)

  check fileExists(failurePath),
    "a never-connecting seat wrote no COGAME_PLAYER_FAILURE_URI artifact"
  if fileExists(failurePath):
    let declared = parseJson(readFile(failurePath))
    check declared{"failed_policy_index"}.getInt(-1) == 1,
      &"the no-show was charged to policy index " &
      $declared{"failed_policy_index"}.getInt(-1) & ", want 1 (the lowest " &
      "missing slot)"
    check "pusher" in declared{"message"}.getStr(),
      "the declaration does not say the no-show's bug plays pusher: " &
      declared{"message"}.getStr()
  check fileExists(resultsPath),
    "a one-seat episode wrote no results — it never reached a normal ending"
  if fileExists(resultsPath):
    let results = parseJson(readFile(resultsPath))
    check results["reason"].getStr() == ReasonComplete,
      &"""a one-seat episode ended {results["reason"].getStr()}, want """ &
      "complete: a no-show must not push the episode onto the wall-clock stop"
    check results["rounds"].getInt() >= 1,
      &"""a one-seat episode banked {results["rounds"].getInt()} rounds""" &
      " — the match must be PLAYED, not waited out"
  ## LOGGED LOUDLY: the phrase phase 60 greps the game log for. The line is
  ## printed by the loop above (it is in this test's own stdout in CI); the
  ## source is pinned so it cannot be quietly dropped.
  let source = readFile(repoFile("src/bodies/server.nim"))
  check source.contains("never registered; driving "),
    "server.nim no longer logs the no-show loudly"
  removeDir(workDir)

# --- SLOT 1 CONNECTS FIRST: held, not thrown away --------------------
block:
  ## The bug that cost 0.1.1 and 0.1.2 their hosted smoke. Joins are
  ## slot-sequential, and PROTOCOL.md promises a seat whose slot is not the next
  ## open one "is not admitted until the lower slots have joined". The admit
  ## loop instead handed that refusal to `except BodiesError`, which latched
  ## `playerIndices[socket] = -1` — PERMANENT. Slot 1 was discarded while still
  ## connected and still acking frames, the lobby waited out its whole budget
  ## for it, and the hosted runner failed the episode "player slot 1 never
  ## joined the lobby". It never reproduced locally because the loop walked a
  ## Table, so WHICH pending socket it reached first was unspecified: 1 of 5
  ## hosted episodes failed at 0.1.1, then 3 of 5 at 0.1.2.
  ##
  ## Connecting slot 1 FIRST makes it deterministic: with only slot 1 pending,
  ## the old code refused and latched it on the very next iteration.
  let
    workDir = tempPath("engine-slotorder")
    failurePath = workDir / "player-failure.json"
    resultsPath = workDir / "slotorder-results.json"
  createDir(workDir)
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & failurePath)
  var cfg = defaultGameConfig()
  cfg.seed = 5104773
  cfg.players = @[PlayerConfig(name: "BUG-1"), PlayerConfig(name: "BUG-2")]
  cfg.maxGames = 1
  cfg.maxRounds = 1
  cfg.roundsToClinch = 1
  cfg.roundTicks = 48
  cfg.resetTicks = 12
  cfg.maxTicks = 240
  cfg.turnTicks = 24
  cfg.turnSpacingMs = 0
  cfg.wallClockBudgetSeconds = 120
  cfg.lobbyJoinTimeoutTicks = 168     ## 7 s — long enough for both connects
  cfg.startWaitTicks = 12
  cfg.gameOverTicks = 12
  cfg.fastMode = true
  createThread(gameThread2, gameServeProc, GameServerArgs(cfg: cfg, port: 8795,
    runtime: RuntimeConfig(host: "127.0.0.1", port: 8795,
      resultsUri: "file://" & resultsPath)))

  proc connectSeat(slot: int, label: string): whisky.WebSocket =
    result = nil
    for _ in 0 ..< 60:
      try:
        result = whisky.newWebSocket(
          "ws://127.0.0.1:8795/player?slot=" & $slot)
        break
      except CatchableError:
        sleep(100)
    if result != nil:
      whisky.send(result, blobFromSpriteChat($(%*{
        "type": "register", "kind": "scripted", "scripted": "pusher",
        "policy": label})), whisky.BinaryMessage)

  ## SLOT 1 FIRST, then slot 0 — with a real gap, so the admit loop sees slot 1
  ## pending ALONE for a dozen frames. That is the shape the old code threw the
  ## seat away on.
  let high = connectSeat(1, "test-slotorder-1")
  check high != nil, "seat 1 could not connect to the in-process server"
  sleep(700)
  let low = connectSeat(0, "test-slotorder-0")
  check low != nil, "seat 0 could not connect to the in-process server"
  let deadline = epochTime() + 120.0
  while epochTime() < deadline and not fileExists(resultsPath):
    for socket in [low, high]:
      if socket == nil: continue
      try:
        if whisky.receiveMessage(socket, timeout = 120).isSome:
          whisky.send(socket, blobFromSpriteReady(), whisky.BinaryMessage)
      except CatchableError:
        discard
  for socket in [low, high]:
    if socket != nil:
      try: whisky.close(socket) except CatchableError: discard
  joinThread(gameThread2)

  check not fileExists(failurePath),
    "slot 1 connecting BEFORE slot 0 was declared a no-show — a seat whose " &
    "slot is not the next open one must be HELD until the lower slots join, " &
    "not refused and latched"
  check fileExists(resultsPath),
    "an out-of-order two-seat lobby wrote no results"
  if fileExists(resultsPath):
    let results = parseJson(readFile(resultsPath))
    check results["reason"].getStr() == ReasonComplete,
      &"""an out-of-order lobby ended {results["reason"].getStr()}, want """ &
      "complete"
    check results["rounds"].getInt() >= 1,
      "an out-of-order lobby banked no rounds — the match must be PLAYED"
    ## Both seats registered, so neither policyKind may read `scripted` by
    ## default and both names must be the real ones.
    check results["names"][0].getStr() == "test-slotorder-0" or
        results["names"][0].getStr() == "BUG-1",
      "seat 0's name was not recorded: " & results["names"][0].getStr()
  removeDir(workDir)


if failures > 0:
  quit("test_engine: " & $failures & " failure(s)", 1)
echo "test_engine: ok"
## Exit WITHOUT running the module teardown. The in-process GAME server above
## leaves mummy and pixie allocations shared across threads, and tearing
## them down from an exiting main thread segfaults on a GREEN run — which would
## read as a test failure. tests/test_server.nim ends the same way, for the same
## reason.
quit(0)
