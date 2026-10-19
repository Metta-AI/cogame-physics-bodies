## Stream complete private candidate matches; shared review owns training admission.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]

import std/[json, os, osproc, strutils]
import bodies/[sim, intents, control, baselines, llm, prompts, evidence]

const OperatorPrompt = "Win the ring match using only your own observation."

proc main() =
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "default"
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len == 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin ["default", "blitz"]:
    quit("variant must be default or blitz", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let sourceRevision = head.output.strip()
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  defer: stream.close()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    let family = "physics-bodies-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
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
      decisions = 0
      pending = newJArray()
      lastTurn = -1
    for seat in 0 ..< BodyCount:
      intents[seat] = defaultIntent()
    while sim.phase != GameOver:
      if sim.phase == Playing:
        let turn = sim.tickCount div config.turnTicks
        if sim.tickCount mod config.turnTicks == 0 and turn != lastTurn:
          lastTurn = turn
          for record in pending: stream.writeLine($record)
          pending = newJArray()
          for seat in 0 ..< BodyCount:
            let view = seatView(sim, seat, haveIntent[seat], intents[seat])
            let teacher = scriptedIntent(ctl.params, view, blPusher)
            let completion = teacher.intentAction()
            let parsed = parseIntentReply($completion, intents[seat], haveIntent[seat])
            doAssert parsed.stance == teacher.stance
            doAssert parsed.aim == teacher.aim
            doAssert parsed.bearingDeg == teacher.bearingDeg
            doAssert parsed.aggression == teacher.aggression
            doAssert parsed.postureBias == teacher.postureBias
            doAssert parsed.leadTicks == teacher.leadTicks
            doAssert parsed.circleDir == teacher.circleDir
            let system = systemPrompt(selection)
            let user = userMessage(OperatorPrompt, seatViewJson(view))
            let messages = %*[{"role": "system", "content": system},
              {"role": "user", "content": user}]
            var observation = parseJson(seatViewJson(view))
            observation["prompt_template"] = selection.promptMetadata(system, user)
            let executed = parsed.intentAction()
            doAssert completion == executed
            let attemptId = $decisions & "-teacher"
            pending.add(%*{
              "schema_version": "1", "event_type": "decision", "episode_id": episode,
              "decision_id": $(turn * BodyCount + seat), "decision_index": decisions,
              "game": "physics-bodies", "game_version": "source-" & sourceRevision,
              "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
              "observation": observation, "prompt": messages,
              "attempts": [{"attempt_id": attemptId, "policy": "scripted-pusher",
                "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
                "response": $completion, "parsed_action": completion, "accepted": true,
                "request": newJNull(), "platform_call_id": newJNull(),
                "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
              "selected_attempt_id": attemptId, "executed_action": executed,
              "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false
            })
            inc decisions
            intents[seat] = parsed
            haveIntent[seat] = true
      var cmds: array[BodyCount, uint8]
      for body in 0 ..< BodyCount:
        let seat = sim.seatOfBody(body)
        let intent = if seat >= 0 and haveIntent[seat]: intents[seat] else: defaultIntent()
        cmds[sim.inputIndexOfBody(body)] = driveCommand(ctl, sim, body, intent, sim.tickCount)
      sim.step(cmds)
    doAssert decisions > 0
    let outcome = parseJson(sim.playerResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete
    for record in pending:
      record["terminal"] = %true
      stream.writeLine($record)
    var participants = newJObject()
    for seat in 0 ..< BodyCount:
      participants[$seat] = %*{"score": outcome["scores"][seat]}
    stream.writeLine($(%*{
      "schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "physics-bodies", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed",
      "outcome": outcome, "participant_outcomes": participants
    }))
    runs.add(%*{"seed": seed, "decisions": decisions,
      "scores": outcome["scores"], "win": outcome["win"]})
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "physics-bodies",
    "variant": variant,
    "source_revision": sourceRevision,
    "prompt_configuration": selection.selectionMetadata(),
    "teacher": "scripted-pusher",
    "operator_prompt": OperatorPrompt,
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", matches

when isMainModule:
  main()
