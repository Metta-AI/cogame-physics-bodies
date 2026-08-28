## 10. An END-TO-END episode that writes a replay, and the record -> re-derive
## check FOR EVERY END REASON — not just `complete`.

import std/[json, os, osproc, strformat, strutils, tables, unicode]
import bodies/[sim, global, broadcast, intents, control, baselines, replays,
               replay_runtime]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

proc rederive(path: string, expectMismatch = false):
    tuple[ok: bool, ticks: int, mismatch: int, phase: GamePhase] =
  ## Re-simulates a recorded replay from its config + command bytes and checks
  ## EVERY recorded hash. This is the same path the wasm viewer runs.
  let data = parseReplayBytes(readFile(path))
  var runtime = initReplayRuntime(data, mismatchQuit = false,
    gameEventLoggingEnabled = false)
  while runtime.player.playing:
    runtime.player.stepReplay(runtime.sim)
  result.ticks = runtime.sim.tickCount
  result.mismatch = runtime.player.hashMismatchTick
  result.phase = runtime.sim.phase
  result.ok = runtime.player.hashMismatchTick < 0

# --- complete / match_won and complete / full_time --------------------
var completePath = ""
block:
  var cfg = defaultMatchConfig()
  let path = tempPath("complete.replay")
  let episode = runEpisode(cfg, [blPusher, blAnchor], path)
  completePath = path
  check fileExists(path), "the episode wrote no replay"
  check episode.sim.endReason == ReasonComplete,
    &"the episode ended {episode.sim.endReason}, want complete"
  check episode.sim.endRule in [EndRuleMatchWon, EndRuleFullTime],
    &"a complete episode ended {episode.sim.endRule}"
  let check1 = rederive(path)
  check check1.ok,
    &"complete/{episode.sim.endRule} re-derived with a hash mismatch at " &
    $check1.mismatch
  check check1.ticks == episode.ticks,
    &"the re-derivation stopped at {check1.ticks}, recording was {episode.ticks}"
  check check1.phase == GameOver,
    "the re-derivation did not reach GameOver"

block:
  ## The cert fixture cannot clinch early (roundsToClinch == maxRounds), so it
  ## is the full_time path.
  var cfg = certConfig()
  let path = tempPath("fulltime.replay")
  let episode = runEpisode(cfg, [blPusher, blPusher], path)
  check episode.sim.endRule == EndRuleFullTime,
    &"the cert fixture ended {episode.sim.endRule}, want full_time"
  let outcome = rederive(path)
  check outcome.ok,
    &"complete/full_time re-derived with a mismatch at {outcome.mismatch}"
  ## THE CERT FIXTURE AT SEED 5104773 PRODUCES >= 480 TICKS. The viewer smoke
  ## soaks for 12 s (288 ticks) and a replay shorter than the soak reads as
  ## "frozen" (ecos, 2026-08-23).
  check episode.ticks >= 480,
    &"the certification fixture produced {episode.ticks} ticks, want >= 480"
  removeFile(path)

# --- deadline / wall_clock -------------------------------------------
block:
  ## The wall-clock stop is the ONE fact playback cannot re-derive from the
  ## action log, so it rides as a load-bearing `stop` record applied by the same
  ## proc on both sides (cogame-particle-worlds 13c66d7).
  var cfg = certConfig()
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  var ctl = initControlState()
  let path = tempPath("deadline.replay")
  var writer = openReplayWriter(path, cfg.configJson(sim.perm))
  for seat in 0 ..< BodyCount:
    discard sim.addPlayer("seat-" & $seat, seat, "")
    writer.writeJoin(tickTime(sim.tickCount), seat, "seat-" & $seat, seat, "")
  var
    cmds = newSeq[uint8](BodyCount)
    lastIntent: array[BodyCount, BugIntent]
    haveIntent: array[BodyCount, bool]
  for i in 0 ..< BodyCount:
    lastIntent[i] = defaultIntent()
  const StopAt = 700
  while sim.tickCount < StopAt and sim.phase != GameOver:
    if sim.phase == Playing and sim.tickCount mod cfg.turnTicks == 0:
      for seat in 0 ..< BodyCount:
        lastIntent[seat] = scriptedIntent(ctl.params,
          seatView(sim, seat, haveIntent[seat], lastIntent[seat]), blPusher)
        haveIntent[seat] = true
    for i in 0 ..< BodyCount:
      let seat = sim.seatOfBody(i)
      let row = sim.inputIndexOfBody(i)
      cmds[row] = driveCommand(ctl, sim, i,
        (if seat >= 0 and haveIntent[seat]: lastIntent[seat]
         else: defaultIntent()), sim.tickCount)
      writer.writeInputMaskChange(tickTime(sim.tickCount), row, cmds[row])
    sim.step(cmds)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  ## The stop, exactly as the server writes it: record FIRST, apply, then one
  ## more (GameOver, no-op) tick so the stop lands INSIDE the hash chain.
  writer.writeChat(tickTime(sim.tickCount), 0,
    stopRecord(sim.tickCount, "wall_clock"))
  sim.applyWallClockStop(int32(sim.tickCount))
  sim.step(cmds)
  writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  writer.closeReplayWriter()
  check sim.endReason == ReasonDeadline and sim.endRule == EndRuleWallClock,
    &"the deadline episode ended {sim.endReason}/{sim.endRule}"
  let outcome = rederive(path)
  check outcome.ok,
    &"deadline/wall_clock re-derived with a mismatch at {outcome.mismatch}"
  check outcome.phase == GameOver,
    "the re-derived deadline episode did not reach GameOver"
  removeFile(path)

# --- fault / sim_fault: a PARTIAL replay that still re-derives --------
block:
  var cfg = certConfig()
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  var ctl = initControlState()
  let path = tempPath("fault.replay")
  var writer = openReplayWriter(path, cfg.configJson(sim.perm))
  for seat in 0 ..< BodyCount:
    discard sim.addPlayer("seat-" & $seat, seat, "")
    writer.writeJoin(tickTime(sim.tickCount), seat, "seat-" & $seat, seat, "")
  var cmds = newSeq[uint8](BodyCount)
  var faulted = false
  for tick in 0 ..< 400:
    for i in 0 ..< BodyCount:
      let row = sim.inputIndexOfBody(i)
      cmds[row] = driveCommand(ctl, sim, i, defaultIntent(), sim.tickCount)
      writer.writeInputMaskChange(tickTime(sim.tickCount), row, cmds[row])
    if tick == 300:
      ## Corrupt a hashed field the guard checks and that no earlier step
      ## repairs. `hMilli` is wrapped by the yaw servo and `px` is clamped by
      ## step 8, so the reachable trigger is the round clock running past its
      ## own bound.
      sim.roundTick = int32(cfg.roundTicks + 5)
    try:
      sim.step(cmds)
    except SimGuardError:
      faulted = true
      sim.endReason = ReasonFault
      sim.endRule = EndRuleSimFault
      sim.phase = GameOver
      break
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  writer.closeReplayWriter()
  check faulted, "the injected corruption did not trip the sim guard"
  let outcome = rederive(path)
  check outcome.ok,
    &"fault/sim_fault's PARTIAL replay re-derived with a mismatch at " &
    $outcome.mismatch
  let results = parseJson(sim.playerResultsJson())
  check results["reason"].getStr() == "fault" and
    results["endRule"].getStr() == "sim_fault",
    "a faulted episode did not report fault/sim_fault"
  removeFile(path)

# --- a PARTIAL LOBBY: one seat never joins, and it still re-derives ---
block:
  ## §End conditions: a seat that never connects does not end the episode. The
  ## lobby budget expires, the round starts anyway, and the no-show's bug plays
  ## the scripted baseline for the whole run. The force-start is derived INSIDE
  ## `step` from `lobbyTicks` and the recorded joins, so playback must reach the
  ## same start tick — a server-side force-start would diverge here at the
  ## first tick of round 1.
  var cfg = defaultMatchConfig()
  cfg.lobbyJoinTimeoutTicks = 240
  cfg.maxRounds = 1
  cfg.roundsToClinch = 1
  cfg.maxTicks = cfg.roundTicks + cfg.resetTicks
  let path = tempPath("noshow.replay")
  let episode = runEpisode(cfg, [blPusher, blAnchor], path, seatsJoined = 1)
  check episode.sim.players.len == 1,
    &"the partial lobby seated {episode.sim.players.len} players, want 1"
  check episode.sim.lobbyNoShowSeat == 1,
    &"the no-show seat was latched as {episode.sim.lobbyNoShowSeat}, want 1"
  check episode.sim.gameStartTick == cfg.lobbyJoinTimeoutTicks - 1,
    &"the round started at tick {episode.sim.gameStartTick}, want the lobby " &
    &"budget {cfg.lobbyJoinTimeoutTicks - 1} — a never-joining seat must not " &
    "hold the lobby for the whole wall-clock budget"
  check episode.sim.endReason == ReasonComplete,
    &"a one-seat episode ended {episode.sim.endReason}, want complete"
  check episode.sim.roundLog.len == 1,
    &"a one-seat episode banked {episode.sim.roundLog.len} rounds, want 1 — " &
    "the match must play to a normal ending"
  ## BOTH bugs were commanded: a no-show leaves no bug uncommanded.
  var moved = 0
  for i in 0 ..< BodyCount:
    if episode.sim.bodies[i].contacts > 0 or
        episode.sim.effortTicks[i] > 0:
      inc moved
  check moved == BodyCount,
    &"only {moved} of {BodyCount} bugs were driven in a one-seat episode"
  let outcome = rederive(path)
  check outcome.ok,
    &"the partial-lobby episode re-derived with a hash mismatch at " &
    $outcome.mismatch
  check outcome.ticks == episode.ticks,
    &"the partial-lobby re-derivation stopped at {outcome.ticks}, recording " &
    &"was {episode.ticks}"
  removeFile(path)

# --- the recorded stream's shape -------------------------------------
block:
  var cfg = defaultMatchConfig()
  let path = tempPath("shape.replay")
  ## A NON-ASCII say and a NON-ASCII policy label, so the UTF-8 path is real.
  let episode = runEpisode(cfg, [blPusher, blPusher], path,
    sayOverride = "caf\u00e9 \u2014 \u1F980 walking it to the edge",
    labelOverride = "champion caf\u00e9")
  let data = parseReplayBytes(readFile(path))
  check data.gameName == GameName and data.gameVersion == GameVersion,
    "the replay header does not carry the game name/version"
  check data.hashes.len == episode.ticks,
    &"the replay has {data.hashes.len} hashes for {episode.ticks} ticks"
  check data.joins.len == BodyCount,
    &"the replay has {data.joins.len} joins, want {BodyCount}"

  ## The embedded config JSON decodes strictly and carries the seed, perm and
  ## the whole geometry table.
  let config = parseJson(data.configJson)
  check config.hasKey("seed") and config.hasKey("perm"),
    "the replay config is missing seed / perm"
  check config["perm"].len == BodyCount, "the replay config's perm is malformed"
  for key in ["ringRadiusUm", "ringRadiusMinUm", "ringShrinkPerTickUm",
              "shrinkStartTick"]:
    check config.hasKey(key),
      &"the replay config does not pin {key} at TOP LEVEL — playback would " &
      "fall back to this build's default and diverge"
  check config.hasKey("geometry") and
    config["geometry"].hasKey("reachByPosture"),
    "the replay config is missing the geometry table"

  var registers, intents, rounds, results = 0
  var intentTurns: seq[int]
  for chat in data.chats:
    if chat.message.len == 0 or chat.message[0] != '{':
      continue
    let node = parseJson(chat.message)
    case node{"k"}.getStr()
    of "register":
      inc registers
    of "intent":
      inc intents
      intentTurns.add node{"turn"}.getInt()
      check chat.message.runeLen <= MaxIntentRunes,
        &"an intent record is {chat.message.runeLen} runes, cap " &
        $MaxIntentRunes
      check node{"say"}.getStr().validateUtf8() == -1,
        "a recorded say is not valid UTF-8"
    of "round":
      inc rounds
    of "result":
      inc results
    else:
      discard
  check registers == BodyCount,
    &"the stream has {registers} register records, want {BodyCount}"
  check results == 1, &"the stream has {results} result records, want 1"
  check rounds == episode.sim.roundLog.len,
    &"the stream has {rounds} round records for " &
    $episode.sim.roundLog.len & " completed rounds"
  ## Two intent records per turn.
  var perTurn = initTable[int, int]()
  for turn in intentTurns:
    perTurn[turn] = perTurn.getOrDefault(turn) + 1
  for turn, count in perTurn:
    check count == BodyCount,
      &"turn {turn} has {count} intent records, want {BodyCount}"
  check intents >= 2, "the stream carries almost no intent records"

  ## At least one contact happened.
  var contacts = 0
  for i in 0 ..< BodyCount:
    contacts += int(episode.sim.bodies[i].contacts)
  check contacts > 0, "the episode recorded no contact at all"

  ## results.reason / endRule are in the legal enums.
  let results2 = parseJson(episode.sim.playerResultsJson())
  check results2["reason"].getStr() in ["complete", "deadline", "fault"],
    "results.reason is outside its enum"
  check results2["endRule"].getStr() in ["match_won", "full_time",
    "wall_clock", "sim_fault", "host_error"],
    "results.endRule is outside its enum"

  ## tools/replay_summary.py parses under a STRICT UTF-8 JSON parser.
  let script = repoFile("tools/replay_summary.py")
  let run = execCmdEx(&"python3 {script} {path}")
  check run.exitCode == 0,
    &"replay_summary.py exited {run.exitCode}: {run.output}"
  if run.exitCode == 0:
    check run.output.validateUtf8() == -1,
      "replay_summary.py emitted invalid UTF-8"
    let summary = parseJson(run.output)
    check summary["protocol"].getStr() == "physics-bodies/v1",
      "replay_summary.py reported the wrong protocol"
    check summary["tickCount"].getInt() == episode.ticks,
      "replay_summary.py disagrees about the tick count"
    check summary["results"]["reason"].getStr() ==
      results2["reason"].getStr(),
      "replay_summary.py disagrees about results.reason"
  removeFile(path)

if fileExists(completePath):
  removeFile(completePath)
if failures > 0:
  quit("test_replay: " & $failures & " failure(s)", 1)
echo "test_replay: ok"
