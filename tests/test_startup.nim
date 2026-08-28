## 14. Startup: a clean message and a non-zero exit when the runtime config is
## missing or unparseable, the seed randomised BEFORE config.update, and both
## entrypoints present and executable in the image.

import std/[json, os, osproc, strformat, strutils]
import bodies/[sim, intents]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

# --- an unparseable config is a CLEAN refusal, not a traceback --------
block:
  var config = defaultGameConfig()
  var raised = false
  var message = ""
  try:
    config.update("{not json at all")
  except BodiesError as error:
    raised = true
    message = error.msg
  check raised, "an unparseable config did not raise"
  check message.contains("not valid JSON"),
    &"the refusal message is not readable: {message}"
  var raisedShape = false
  try:
    var other = defaultGameConfig()
    other.update("[1, 2, 3]")
  except BodiesError:
    raisedShape = true
  check raisedShape, "a non-object config did not raise"
  ## An EMPTY config is not an error: the defaults are a complete game.
  var empty = defaultGameConfig()
  empty.update("")
  check empty.numAgents == BodyCount,
    "an empty config did not fall back to the defaults"

# --- the seed is honoured when pinned, and every draw follows it -----
block:
  var pinned = defaultGameConfig()
  pinned.update($(%*{"seed": 4242}))
  check pinned.seed == 4242, "a pinned seed was not honoured"
  let a = initSimServer(pinned)
  let b = initSimServer(pinned)
  check a.perm == b.perm and a.startAxis == b.startAxis,
    "a pinned seed did not reproduce the same seeded layout"
  ## …and a DIFFERENT seed really does move the layout, so the randomisation in
  ## the entrypoint is not decorative.
  var other = defaultGameConfig()
  other.update($(%*{"seed": 4243}))
  let c = initSimServer(other)
  check a.startAxis != c.startAxis or a.perm != c.perm,
    "two different seeds produced an identical seeded layout"

# --- the entrypoint randomises BEFORE config.update ------------------
block:
  ## The order is the whole point: every seed-derived draw (perm, all five
  ## start axes) is taken inside initSimServer from the FINAL seed, so a
  ## randomisation that happened after the parse would be ignored.
  let source = readFile(repoFile("src/physics_bodies.nim"))
  let randomAt = source.find("config.seed = randomSeed()")
  let updateAt = source.find("config.update(stripUnpinnedSeed(")
  check randomAt >= 0 and updateAt > randomAt,
    "src/physics_bodies.nim does not randomise the seed BEFORE config.update"
  check source.contains("quit(\"physics-bodies: cannot read the runtime " &
    "config: \" & error.msg, 1)"),
    "the entrypoint does not exit non-zero with a clean message when the " &
    "runtime config cannot be read"

# --- both entrypoints are declared, and the image copies both -------
block:
  check fileExists(repoFile("src/physics_bodies.nim")),
    "src/physics_bodies.nim is missing"
  check fileExists(repoFile("src/physics_bodies_player.nim")),
    "src/physics_bodies_player.nim is missing"
  let dockerfile = readFile(repoFile("Dockerfile"))
  for binary in ["/bin/physics-bodies", "/bin/physics-bodies-player"]:
    check dockerfile.contains(binary),
      &"the Dockerfile does not install {binary}"
  check dockerfile.contains("CMD [\"/bin/physics-bodies\"]"),
    "the Dockerfile's CMD is not the game server"
  ## The image needs the data AND the client directories: the board plate is
  ## baked from data/arena_floor.png and client/art/walls at RUNTIME.
  check dockerfile.contains("./data") and dockerfile.contains("./client"),
    "the runtime stage does not copy data/ and client/"
  let manifest = parseJson(readFile(repoFile("coworld_manifest_template.json")))
  check manifest["game"]["runnable"]["run"][0].getStr() ==
    "/bin/physics-bodies",
    "the manifest does not run /bin/physics-bodies"
  for entry in manifest["player"]:
    check entry["run"][0].getStr() == "/bin/physics-bodies-player",
      "a declared player does not run /bin/physics-bodies-player"
  let policies = parseJson(readFile(repoFile("tools/ci/policies.json")))
  check policies.len == 4,
    &"tools/ci/policies.json declares {policies.len} policies, want 4"
  var prompts = 0
  var scripted = 0
  var owned = 0
  for policy in policies:
    check policy["run"].getStr() == "/bin/physics-bodies-player",
      "a policy does not run /bin/physics-bodies-player"
    if policy["env"].hasKey("PLAYER_PROMPT"):
      inc prompts
      check policy["env"]["PLAYER_PROMPT"].getStr().len > 200,
        "an LLM policy's prompt is too short to be a strategy"
    if policy["env"].hasKey("PLAYER_SCRIPTED"):
      inc scripted
      check policy["env"]["PLAYER_SCRIPTED"].getStr() in ["pusher", "anchor"],
        "a scripted policy names an unpublished baseline"
    if policy.hasKey("player"):
      inc owned
  check prompts == 2, &"{prompts} LLM prompt policies, want exactly 2"
  check scripted == 2, &"{scripted} scripted baselines, want 2"
  check owned == 1,
    "champion #2 does not carry the `player` field that owns its version"
  check policies[1]["player"].getStr() ==
    "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
    "champion #2's owning player id is wrong"
  ## The two champion prompts must DIFFER — two identical prompts are one
  ## policy entered twice.
  check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
    policies[1]["env"]["PLAYER_PROMPT"].getStr(),
    "the two champions share one prompt"

# --- the build hooks are committed EXECUTABLE ------------------------
block:
  when defined(posix):
    for hook in ["tools/build_replay_viewer.sh", "tools/ci/docker_smoke.sh"]:
      let path = repoFile(hook)
      check fileExists(path), &"{hook} is missing"
      if fileExists(path):
        let permissions = getFilePermissions(path)
        check fpUserExec in permissions,
          &"{hook} is not executable — `coworld build` hard-requires os.X_OK " &
          "on the replay-viewer hook, and ci.yml asserts the bit on both"

if failures > 0:
  quit("test_startup: " & $failures & " failure(s)", 1)
echo "test_startup: ok"
