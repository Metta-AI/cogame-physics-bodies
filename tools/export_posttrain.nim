## Export complete native matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [default|blitz]

import std/[json, os, osproc, strutils]
import bodies/[sim, intents, control, baselines, llm]

const OperatorPrompt = "Win the ring match using only your own observation."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [default|blitz]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin ["default", "blitz"]:
    quit("variant must be default or blitz", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %["t0", "t1"]
    config.update($runtimeConfig)
    config.seed = seed
    var sim = initSimServer(config)
    sim.gameEventLoggingEnabled = false
    for seat in 0 ..< BodyCount:
      discard sim.addPlayer("policy-" & $seat, seat, "t" & $seat)
    var
      ctl = initControlState()
      intents: array[BodyCount, BugIntent]
      haveIntent: array[BodyCount, bool]
      rows: seq[string]
      lastTurn = -1
    for seat in 0 ..< BodyCount:
      intents[seat] = defaultIntent()
    while sim.phase != GameOver:
      if sim.phase == Playing:
        let turn = sim.tickCount div config.turnTicks
        if sim.tickCount mod config.turnTicks == 0 and turn != lastTurn:
          lastTurn = turn
          for seat in 0 ..< BodyCount:
            let view = seatView(sim, seat, haveIntent[seat], intents[seat])
            let teacher = scriptedIntent(ctl.params, view, blPusher)
            let completion = %*{
              "note": teacher.note,
              "stance": $teacher.stance,
              "aim": $teacher.aim,
              "bearing_deg": teacher.bearingDeg,
              "aggression": teacher.aggression,
              "posture_bias": $teacher.postureBias,
              "lead_ticks": teacher.leadTicks,
              "circle_dir": teacher.circleDir,
              "say": teacher.say
            }
            let parsed = parseIntentReply($completion, intents[seat], haveIntent[seat])
            doAssert parsed.stance == teacher.stance
            doAssert parsed.aim == teacher.aim
            doAssert parsed.bearingDeg == teacher.bearingDeg
            doAssert parsed.aggression == teacher.aggression
            doAssert parsed.postureBias == teacher.postureBias
            doAssert parsed.leadTicks == teacher.leadTicks
            doAssert parsed.circleDir == teacher.circleDir
            rows.add($(%*{
              "episode_id": "physics-bodies-" & variant & "-" & $seed,
              "seed": "physics-bodies-" & variant & "-" & $seed,
              "decision_id": turn * BodyCount + seat,
              "prompt": [
                {"role": "system", "content": SystemPrompt},
                {"role": "user", "content": userMessage(OperatorPrompt, seatViewJson(view))}
              ],
              "completion": [{"role": "assistant", "content": $completion}],
              "game": "physics-bodies",
              "action_schema_revision": "ring-intent-v1"
            }))
            intents[seat] = parsed
            haveIntent[seat] = true
      var cmds: array[BodyCount, uint8]
      for body in 0 ..< BodyCount:
        let seat = sim.seatOfBody(body)
        let intent = if seat >= 0 and haveIntent[seat]: intents[seat] else: defaultIntent()
        cmds[sim.inputIndexOfBody(body)] = driveCommand(ctl, sim, body, intent, sim.tickCount)
      sim.step(cmds)
    doAssert rows.len > 0
    let outcome = parseJson(sim.playerResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "win": outcome["win"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "physics-bodies",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-pusher",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
