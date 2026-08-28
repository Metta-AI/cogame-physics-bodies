## THE RING — the game server entrypoint.
##
## Seed randomization happens HERE, BEFORE `config.update`, so every
## seed-derived draw (the seat/body permutation and all five start axes) follows
## the FINAL seed. With a public fixed seed the start-axis draws would be
## pre-computable by an opponent.

import std/[json, os, sysrand]
import bitworld/runtime
import bodies/sim
import bodies/server

const LegacyFixedSeed = 0
  ## "Nobody chose a seed": a config carrying no seed, or a zero seed, gets a
  ## fresh random one.

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a non-sentinel seed (fixture
  ## recordings, A/B batteries, forensic re-runs).
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false                      ## config.update reports the real parse error.

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(BodiesError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let runtimeConfig =
    try:
      readRuntimeConfig()
    except CatchableError as error:
      ## A clean message and a non-zero exit, never a traceback: this is the
      ## first thing an operator reads when an episode never started.
      quit("physics-bodies: cannot read the runtime config: " & error.msg, 1)

  var config = defaultGameConfig()
  try:
    if seedPinned(runtimeConfig.config):
      config.update(runtimeConfig.config)
    else:
      config.seed = randomSeed()
      config.update(stripUnpinnedSeed(runtimeConfig.config))
      echo "seed not pinned; randomized"
  except CatchableError as error:
    quit("physics-bodies: " & error.msg, 1)

  let localReplayPath =
    if runtimeConfig.replayUri.len > 0:
      getTempDir() / ("physics-bodies-" & $getCurrentProcessId() & ".replay")
    else:
      ""
  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("physics-bodies-load-" &
        $getCurrentProcessId() & ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  echo "physics-bodies config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " num_agents=", config.numAgents,
    " maxTicks=", config.maxTicks,
    " rounds=", config.maxRounds,
    " toClinch=", config.roundsToClinch,
    " turnTicks=", config.turnTicks,
    " wallClock=", config.wallClockBudgetSeconds, "s"
  echo "starting physics-bodies on ", runtimeConfig.host, ":",
    runtimeConfig.port

  runServerLoop(runtimeConfig.host, runtimeConfig.port, config,
    localReplayPath, loadReplayPath, "", runtimeConfig)
