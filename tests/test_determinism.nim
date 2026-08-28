## 2. THE DETERMINISM GATE.
##
## If this suite fails, the physics or a build flag changed. FIX THE CODE, NEVER
## THE TEST: the whole reason the sim is integer-only is that the emscripten
## wasm32 replay viewer re-derives this exact hash chain in a browser.

import std/[json, math, os, strformat, strutils]
import bodies/[sim, intents, control, baselines]
import helpers

proc isIdentChar(ch: char): bool =
  ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc containsWord(line, word: string): bool =
  ## Whole-identifier match, without std/re: `re` needs libpcre at RUNTIME and
  ## a source guard that cannot run in a slim container is a guard nobody has.
  var start = 0
  while true:
    let at = line.find(word, start)
    if at < 0:
      return false
    let
      beforeOk = at == 0 or not isIdentChar(line[at - 1])
      afterAt = at + word.len
      afterOk = afterAt >= line.len or not isIdentChar(line[afterAt])
    if beforeOk and afterOk:
      return true
    start = at + 1

proc callsRand(line: string): bool =
  var start = 0
  while true:
    let at = line.find("rand", start)
    if at < 0:
      return false
    let beforeOk = at == 0 or not isIdentChar(line[at - 1])
    var after = at + 4
    while after < line.len and line[after] == ' ':
      inc after
    if beforeOk and after < line.len and line[after] == '(':
      return true
    start = at + 1

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

proc recordLog(config: GameConfig, ticks: int):
    tuple[hashes: seq[uint64], log: seq[seq[uint8]]] =
  ## One scripted episode, keeping both the hash chain and the command-byte log
  ## so (a) and (b) can replay it.
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var ctl = initControlState()
  for seat in 0 ..< sim.seatCount():
    discard sim.addPlayer("seat-" & $seat, seat, "")
  var
    cmds = newSeq[uint8](BodyCount)
    lastIntent: array[BodyCount, BugIntent]
    haveIntent: array[BodyCount, bool]
    lastTurn = -1
  for i in 0 ..< BodyCount:
    lastIntent[i] = defaultIntent()
  while sim.tickCount < ticks and sim.phase != GameOver:
    if sim.phase == Playing:
      let turn = sim.tickCount div max(1, config.turnTicks)
      if sim.tickCount mod max(1, config.turnTicks) == 0 and turn != lastTurn:
        lastTurn = turn
        for seat in 0 ..< sim.seatCount():
          lastIntent[seat] = scriptedIntent(ctl.params,
            seatView(sim, seat, haveIntent[seat], lastIntent[seat]), blPusher)
          haveIntent[seat] = true
    for i in 0 ..< BodyCount:
      let seat = sim.seatOfBody(i)
      let intent =
        if seat >= 0 and haveIntent[seat]: lastIntent[seat]
        else: defaultIntent()
      cmds[sim.inputIndexOfBody(i)] =
        driveCommand(ctl, sim, i, intent, sim.tickCount)
    result.log.add cmds
    sim.step(cmds)
    result.hashes.add sim.gameHash()

proc replayLog(config: GameConfig, log: seq[seq[uint8]]): seq[uint64] =
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  for seat in 0 ..< sim.seatCount():
    discard sim.addPlayer("seat-" & $seat, seat, "")
  for cmds in log:
    sim.step(cmds)
    result.add sim.gameHash()

let cfg = defaultMatchConfig()

# --- (a) same seed + same byte log => identical hashes at every tick -------
let recorded = recordLog(cfg, MaxTicksDefault)
check recorded.hashes.len > 500,
  &"the recording only reached {recorded.hashes.len} ticks"
block:
  let again = replayLog(cfg, recorded.log)
  check again == recorded.hashes, "a second run in the SAME process diverged"
block:
  let fresh = replayLog(cfg, recorded.log)
  check fresh == recorded.hashes, "a fresh sim diverged from the recording"

# --- (b) a ONE-UNIT change in any command byte changes the final hash ------
block:
  ## Ticks during the LOBBY and the between-rounds hold legitimately ignore
  ## the byte (the controller forces 0 there), so the probes are taken from the
  ## PLAYING span only. The CHAIN must diverge for every probe — that is the
  ## sensitivity the hash exists to provide. The FINAL hash need not always
  ## differ: a round reset re-places both bodies from the seeded start axis, so
  ## a nudge late in a round the reset then wipes can legitimately land back on
  ## the same terminal state. At least one probe must still move it.
  var
    probed = 0
    chainDiverged = 0
    finalMoved = 0
  for index in [300, 500, recorded.log.len div 2, recorded.log.len - 40]:
    if index < 0 or index >= recorded.log.len:
      continue
    var mutated = recorded.log
    var row = mutated[index]
    ## Nudge the DRIVE field, which the dynamics read every tick, rather than a
    ## field a prone bug ignores.
    row[0] = uint8((int(row[0]) + 16) mod 256)
    mutated[index] = row
    let changed = replayLog(cfg, mutated)
    inc probed
    if changed != recorded.hashes:
      inc chainDiverged
    else:
      echo "FAIL: a one-unit command-byte change at ", index,
        " left the WHOLE hash chain unchanged"
      inc failures
    if changed.len != recorded.hashes.len or
        changed[^1] != recorded.hashes[^1]:
      inc finalMoved
  check probed >= 3, "not enough command-byte perturbations were probed"
  check chainDiverged == probed,
    &"only {chainDiverged} of {probed} byte perturbations moved the chain"
  check finalMoved >= 1,
    "no byte perturbation moved the FINAL hash"

# --- (c) the committed golden fixture -------------------------------------
block:
  let path = repoFile("tests/data/golden_hashes.json")
  if not fileExists(path):
    echo "FAIL: tests/data/golden_hashes.json is missing (regenerate with " &
      "tools/gen_golden_hashes.nim)"
    inc failures
  else:
    let golden = parseJson(readFile(path))
    check golden{"seed"}.getInt() == cfg.seed,
      "the golden fixture was cut at a different seed"
    check golden{"gameVersion"}.getStr() == GameVersion,
      "the golden fixture was cut at a different GameVersion — re-record it"
    check golden{"interval"}.getInt() == 48,
      "the golden fixture's interval is not 48"
    var mismatches = 0
    var checked = 0
    for entry in golden{"hashes"}:
      let tick = entry["tick"].getInt()
      if tick < 1 or tick > recorded.hashes.len:
        continue
      inc checked
      ## hashes[i] is the hash AFTER tick i+1, so tick t is index t-1.
      if $recorded.hashes[tick - 1] != entry["hash"].getStr():
        inc mismatches
        if mismatches <= 3:
          echo "FAIL: golden hash mismatch at tick ", tick, ": recorded ",
            recorded.hashes[tick - 1], " golden ", entry["hash"].getStr()
    check checked > 10, &"only {checked} golden ticks were comparable"
    check mismatches == 0, &"{mismatches} golden hash mismatches"

# --- (d) the SOURCE GUARD: no floating point in the hashed modules --------
block:
  const hashed = [
    "src/bodies/sim.nim", "src/bodies/ring.nim", "src/bodies/body.nim",
    "src/bodies/trig.nim", "src/bodies/sim_types.nim",
    "src/bodies/sim_config.nim", "src/bodies/sim_state.nim"
  ]
  ## Comments and doc comments are stripped first: the modules DOCUMENT the
  ## float ban, and a grep that trips over its own prose is a grep nobody keeps.
  let banned = @["sin", "cos", "tan", "arctan", "arcsin", "exp", "ln", "pow",
                 "sqrt", "hypot", "float", "float32", "float64"]
  for relative in hashed:
    let path = repoFile(relative)
    check fileExists(path), &"{relative} is missing"
    if not fileExists(path):
      continue
    for rawLine in readFile(path).splitLines():
      var line = rawLine
      let comment = line.find("##")
      if comment >= 0:
        line = line[0 ..< comment]
      let hash = line.find('#')
      if hash >= 0:
        line = line[0 ..< hash]
      if line.strip().len == 0:
        continue
      for word in banned:
        if containsWord(line, word):
          echo "FAIL: ", relative, " uses floating point / libm: ",
            rawLine.strip()
          inc failures
      if callsRand(line):
        echo "FAIL: ", relative, " calls rand( — only drawInt may draw: ",
          rawLine.strip()
        inc failures
  ## The build scripts must not enable fast math either.
  for relative in ["Dockerfile", "Dockerfile.replay-viewer",
                   "replay-viewer/config.nims", "tools/build_replay_viewer.sh"]:
    let path = repoFile(relative)
    if fileExists(path) and readFile(path).contains("-ffast-math"):
      echo "FAIL: ", relative, " enables -ffast-math"
      inc failures

# --- (e) DirQ12 re-derived, and isqrt checked exhaustively ---------------
block:
  for d in 0 ..< DirCount:
    let
      angle = 11.25 * float(d) * PI / 180.0
      wantX = int32(round(4096.0 * cos(angle)))
      wantY = int32(round(-4096.0 * sin(angle)))
    check DirQ12[d].x == wantX and DirQ12[d].y == wantY,
      &"DirQ12[{d}] is ({DirQ12[d].x}, {DirQ12[d].y}), want ({wantX}, {wantY})"
  var bad = 0
  for v in 0 ..< 65536:
    let r = isqrt(int64(v))
    if r * r > int64(v) or (r + 1) * (r + 1) <= int64(v):
      inc bad
  check bad == 0, &"isqrt was wrong for {bad} values below 2^16"
  var perfect = 0
  var n = 1'i64
  while n * n <= (1'i64 shl 40):
    if isqrt(n * n) != n:
      inc perfect
    n = n * 3 div 2 + 1
  check perfect == 0, &"isqrt was wrong on {perfect} perfect squares to 2^40"

# --- (f) perm and all five start axes are pure functions of the seed ------
block:
  for seed in [0, 1, 5104773, 999_983]:
    var probe = defaultMatchConfig(seed)
    let
      a = initSimServer(probe)
      b = initSimServer(probe)
    check a.perm == b.perm, &"perm is not a pure function of seed {seed}"
    check a.startAxis == b.startAxis,
      &"the start axes are not a pure function of seed {seed}"
    check a.rngDraws == 6,
      &"seed {seed} took {a.rngDraws} draws at t = 0, want exactly 6"
    var seen: array[BodyCount, bool]
    for value in a.perm:
      check value >= 0 and value < BodyCount, "perm is out of range"
      check not seen[value], "perm is not a permutation of 0..1"
      seen[value] = true
    for axis in a.startAxis:
      check axis >= 0 and axis < int32(DirCount),
        &"start axis {axis} is outside 0..31"

# --- (f/g) rngDraws is 6 at the end of every full episode, and identical --
block:
  let episode = runEpisode(cfg)
  check episode.sim.rngDraws == 6,
    &"a full episode ended with rngDraws {episode.sim.rngDraws}, want 6"
  let again = runEpisode(cfg)
  check again.sim.rngDraws == episode.sim.rngDraws,
    "rngDraws differed between two runs of the same command log"
  check again.sim.gameHash() == episode.sim.gameHash(),
    "two runs of the same config ended on different hashes"

if failures > 0:
  quit("test_determinism: " & $failures & " failure(s)", 1)
echo "test_determinism: ok"
