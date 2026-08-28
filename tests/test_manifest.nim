## 12. The manifest template — every invariant the upload contract cares about.

import std/[json, os, strformat, strutils, tables]
import bodies/[sim, intents, control, baselines]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

let manifest = parseJson(readFile(repoFile("coworld_manifest_template.json")))
let game = manifest["game"]

# --- num_agents EVERYWHERE, and NEVER at a variant's top level ---------
block:
  for variant in manifest["variants"]:
    let id = variant["id"].getStr()
    check not variant.hasKey("num_agents"),
      &"variant {id} carries num_agents at its TOP LEVEL — CoworldVariant is " &
      "additionalProperties: false (goofspiel-oshi-zumo 0.1.0)"
    check variant.hasKey("description") and
      variant["description"].getStr().len > 0,
      &"variant {id} has no description"
    let cfg = variant["game_config"]
    let seats = cfg{"num_agents"}.getInt()
    check seats == BodyCount,
      &"variant {id} has num_agents {seats}, want " & $BodyCount
    check cfg{"players"}.len == BodyCount and cfg{"slots"}.len == BodyCount,
      &"variant {id} does not seat exactly {BodyCount} players"
    check not cfg.hasKey("tokens"),
      &"variant {id}'s game_config carries a literal `tokens` — the runner " &
      "injects it and matriculate rejects it (knights-archers 0.1.0)"
  let cert = manifest["certification"]
  check cert["game_config"]{"num_agents"}.getInt() == BodyCount,
    "the certification fixture does not carry num_agents"
  let certSeats = cert["players"].len
  check certSeats == BodyCount,
    &"certification.players has {certSeats} entries, want " & $BodyCount
  check cert["game_config"]{"players"}.len == BodyCount,
    "certification.game_config.players is not one per seat"
  check not cert["game_config"].hasKey("tokens"),
    "the certification game_config carries a literal `tokens`"

# --- every declared player occupies a cert slot, with limits.cpu "1" ---
block:
  var declared: seq[string]
  for entry in manifest["player"]:
    declared.add entry["id"].getStr()
    let cpu = entry["resources"]["limits"]["cpu"].getStr()
    check cpu == "1",
      "player " & entry["id"].getStr() & " has limits.cpu " & cpu &
      " — anything below \"1\" is a 400 at upload (pistonball 0.1.1)"
    check entry.hasKey("type") and entry.hasKey("name") and
      entry.hasKey("description"),
      "a declared player entry is missing id/type/name/description"
  var occupied: seq[string]
  for slot in manifest["certification"]["players"]:
    occupied.add slot["player_id"].getStr()
  for id in declared:
    check id in occupied,
      &"declared player {id} occupies no certification slot — cert fails " &
      "`players_missing` (cogame-raid 0.1.2)"

# --- results_schema == playerResultsJson, key for key ------------------
block:
  var cfg = defaultMatchConfig()
  let episode = runEpisode(cfg)
  let produced = parseJson(episode.sim.playerResultsJson())
  let schema = game["results_schema"]
  check schema{"additionalProperties"}.getBool() == false,
    "results_schema is not additionalProperties: false"
  var schemaKeys: seq[string]
  for key, _ in schema["properties"]:
    schemaKeys.add key
  var producedKeys: seq[string]
  for key, _ in produced:
    producedKeys.add key
  for key in producedKeys:
    check key in schemaKeys,
      &"playerResultsJson emits `{key}`, which results_schema does not declare"
  for key in schemaKeys:
    check key in producedKeys,
      &"results_schema declares `{key}`, which playerResultsJson never emits"
  check schemaKeys.len == 21,
    &"results_schema has {schemaKeys.len} keys, want 21"
  ## Every per-seat array is bounded 2..2.
  const seatArrays = ["names", "aliases", "bodies", "policyKinds", "scores",
    "win", "roundsWon", "ringOuts", "knockouts", "knockdownsSuffered",
    "contacts", "shoveImpulse", "meanEffortPct", "llmTurns", "fallbackTurns"]
  for key in seatArrays:
    let node = schema["properties"][key]
    check node{"minItems"}.getInt() == 2 and node{"maxItems"}.getInt() == 2,
      &"results_schema.{key} is not bounded minItems/maxItems 2"
    check produced[key].len == 2,
      &"playerResultsJson emitted {produced[key].len} entries for {key}"
  check schema["properties"]["roundResults"]{"minItems"}.getInt() == 0 and
    schema["properties"]["roundResults"]{"maxItems"}.getInt() == 5,
    "results_schema.roundResults is not bounded 0..5"
  check schema["properties"]["reason"]["enum"].len == 3,
    "results_schema.reason is not a 3-value enum"
  for value in schema["properties"]["reason"]["enum"]:
    check value.getStr() in ["complete", "deadline", "fault"],
      &"results_schema.reason allows `{value.getStr()}`"
  for value in schema["properties"]["endRule"]["enum"]:
    check value.getStr() in ["match_won", "full_time", "wall_clock",
      "sim_fault", "host_error"],
      &"results_schema.endRule allows `{value.getStr()}`"
  for required in ["names", "scores", "win", "reason", "endRule", "roundsWon",
                   "rounds"]:
    var found = false
    for entry in schema["required"]:
      if entry.getStr() == required:
        found = true
    check found, &"results_schema does not require `{required}`"

# --- config_schema: every array bounded, and it covers what update reads
block:
  let schema = game["config_schema"]
  check schema{"additionalProperties"}.getBool() == false,
    "config_schema is not additionalProperties: false"
  for key, node in schema["properties"]:
    if node{"type"}.getStr() == "array":
      check node.hasKey("minItems") and node.hasKey("maxItems"),
        &"config_schema.{key} is an array with no minItems/maxItems " &
        "(cogame-tandem 0.1.0)"
  for required in ["tokens", "players"]:
    var found = false
    for entry in schema["required"]:
      if entry.getStr() == required:
        found = true
    check found, &"config_schema does not require `{required}`"
  ## EVERY field `sim_config.update` reads must be settable, or it is not a
  ## knob at all. The source is the single list.
  let source = readFile(repoFile("src/bodies/sim_config.nim"))
  var missing: seq[string]
  for line in source.splitLines():
    for marker in ["readInt(node, \"", "readBool(node, \"",
                   "readString(node, \""]:
      var at = line.find(marker)
      while at >= 0:
        let start = at + marker.len
        let stop = line.find('"', start)
        if stop > start:
          let key = line[start ..< stop]
          if not schema["properties"].hasKey(key) and
              key notin ["numAgents"]:
            missing.add key
        at = line.find(marker, at + 1)
  check missing.len == 0,
    "config_schema does not cover fields sim_config.update reads: " & $missing

# --- protocols, docs, description, tags, replay_viewer ----------------
block:
  for key in ["player", "global"]:
    check game["protocols"].hasKey(key),
      &"game.protocols is missing `{key}`"
    let node = game["protocols"][key]
    check node.kind == JObject and node{"type"}.getStr() == "text" and
      node{"value"}.getStr().len > 200,
      &"game.protocols.{key} is not a non-empty {{type:text, value}} object " &
      "(garble v0.1.0)"
  check game["docs"]["readme"]{"type"}.getStr() == "text" and
    game["docs"]["readme"]{"value"}.getStr().len > 200,
    "game.docs.readme is not non-empty text"
  let pageCount = game["docs"]["pages"].len
  check pageCount == 3, &"game.docs.pages has {pageCount} entries, want 3"
  for page in game["docs"]["pages"]:
    check page.hasKey("id") and page.hasKey("title"),
      "a docs page is missing id/title"
    check page["content"]{"type"}.getStr() == "text" and
      page["content"]{"value"}.getStr().len > 200,
      "docs page " & page["id"].getStr() & " is not non-empty text"
  check game.hasKey("description") and game["description"].getStr().len > 0,
    "game.description is missing (pistonball 0.1.0)"
  check not game.hasKey("tags"),
    "game.tags exists — the validator FORBIDS it; tags are top-level"
  let tagCount = manifest["tags"].len
  check tagCount >= 3, &"top-level tags has {tagCount} entries, want >= 3"
  check game["replay_viewer"]{"bundle"}.getStr() == "static-replay-viewer",
    "game.replay_viewer.bundle is not `static-replay-viewer`"
  check not manifest.hasKey("version"),
    "the manifest carries a top-level `version`"
  check not game.hasKey("display_name"), "game.display_name exists"
  check game.hasKey("owner") and game["owner"].getStr().len > 0,
    "game.owner is missing"
  check manifest.hasKey("episode_timeout_minutes"),
    "episode_timeout_minutes is missing"

# --- the arithmetic every variant must satisfy ------------------------
block:
  let episodeTimeout = manifest["episode_timeout_minutes"].getInt() * 60
  for variant in manifest["variants"]:
    let
      id = variant["id"].getStr()
      cfg = variant["game_config"]
      maxTicks = cfg{"maxTicks"}.getInt()
      turnTicks = cfg{"turnTicks"}.getInt()
      roundTicks = cfg{"roundTicks"}.getInt()
      resetTicks = cfg{"resetTicks"}.getInt()
      maxRounds = cfg{"maxRounds"}.getInt()
      clinch = cfg{"roundsToClinch"}.getInt()
      wallClock = cfg{"wallClockBudgetSeconds"}.getInt()
    check wallClock <= (episodeTimeout * 6) div 10,
      &"variant {id}'s wallClockBudgetSeconds {wallClock} is over 60 % of " &
      &"episodeTimeoutSeconds {episodeTimeout}"
    check cfg{"attempt1Ms"}.getInt() + cfg{"retryMs"}.getInt() <=
      cfg{"turnBudgetMs"}.getInt(),
      &"variant {id}: attempt1Ms + retryMs > turnBudgetMs"
    check maxTicks mod turnTicks == 0,
      &"variant {id}: maxTicks {maxTicks} is not a multiple of turnTicks"
    check (roundTicks + resetTicks) mod turnTicks == 0,
      &"variant {id}: roundTicks + resetTicks is not a multiple of turnTicks"
    check maxRounds * (roundTicks + resetTicks) == maxTicks,
      &"variant {id}: maxRounds x (roundTicks + resetTicks) != maxTicks"
    check clinch <= maxRounds,
      &"variant {id}: roundsToClinch {clinch} > maxRounds {maxRounds}"

# --- the compose service name IS the image placeholder ---------------
block:
  let compose = readFile(repoFile("compose.yaml"))
  var service = ""
  var image = ""
  for rawLine in compose.splitLines():
    let line = rawLine.strip()
    if line.endsWith(":") and rawLine.startsWith("  ") and
        not rawLine.startsWith("    ") and service.len == 0:
      service = line[0 ..< line.len - 1]
    if line.startsWith("image:"):
      image = line[6 .. ^1].strip()
  check service == "physics-bodies",
    &"the compose service is `{service}`, want `physics-bodies`"
  check image == "coworld-physics-bodies:latest",
    &"the compose image is `{image}`, want coworld-physics-bodies:latest"
  let placeholder = "{{" & service.toUpperAscii().replace("-", "_") &
    "_IMAGE}}"
  let manifestImage = game["runnable"]["image"].getStr()
  check manifestImage == placeholder,
    &"the manifest image is {manifestImage}, and the compose service derives " &
    &"{placeholder} (cogame-lantern 0.1.0)"
  for entry in manifest["player"]:
    check entry["image"].getStr() == placeholder,
      "a declared player's image is not the derived placeholder"

# --- the secret namespace EQUALS game.name --------------------------
block:
  let uri = game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr()
  check uri == "secret://coworld/" & game["name"].getStr() &
    "/anthropic_api_key",
    &"the secret namespace `{uri}` does not equal game.name " &
    "(cooperative-hunting, 2026-08-25)"
  let manifestName = game["name"].getStr()
  check manifestName == GameName,
    &"game.name `{manifestName}` != the engine's GameName `{GameName}`"

# --- the certification fixture matches SMOKE_SEATS and the design ----
block:
  let cert = manifest["certification"]["game_config"]
  check cert{"seed"}.getInt() == 5104773,
    "the certification fixture is not pinned to seed 5104773"
  check cert{"roundsToClinch"}.getInt() == cert{"maxRounds"}.getInt(),
    "the certification fixture can clinch early — every round must play"
  check cert{"ringShrinkPerTickUm"}.getInt() == 0,
    "the certification fixture still shrinks the ring"
  check cert{"turnSpacingMs"}.getInt() == 0,
    "the certification fixture pays the inter-batch rate floor offline"
  let smoke = readFile(repoFile("tools/ci/docker_smoke.sh"))
  check smoke.contains("SMOKE_SEATS"), "docker_smoke.sh lost SMOKE_SEATS"
  let ci = readFile(repoFile(".github/workflows/ci.yml"))
  check ci.contains("SMOKE_SEATS: \"2\""),
    "ci.yml does not declare SMOKE_SEATS 2 (the cross-check against " &
    "certification.game_config.num_agents)"
  check ci.contains("SMOKE_REQUIRE_REPLAY_JSON: \"0\""),
    "ci.yml does not set SMOKE_REQUIRE_REPLAY_JSON 0 for the binary replay"
  let release = readFile(repoFile(".github/workflows/coworld-release.yml"))
  check release.contains("--timeout-seconds 300"),
    "coworld-release.yml's certify step does not pass --timeout-seconds 300 " &
    "(cooperative-hunting 0.1.2)"

if failures > 0:
  quit("test_manifest: " & $failures & " failure(s)", 1)
echo "test_manifest: ok"
