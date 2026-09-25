## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:physics-bodies-train-bridge tools/train_bridge.nim

import std/[json, os]
import bodies/[baselines, control, intents, sim]
import policy_prompt

const
  OperatorPrompt = "Win the ring match using only your own observation."
  Variants = ["default", "blitz"]
  Stances = ["charge", "brace", "circle", "lift", "retreat", "centre"]
  Aims = ["foe", "centre", "bearing"]
  Postures = ["low", "even", "high", "auto"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc choices(name: string): JsonNode =
  result = newJArray()
  case name
  of "stance":
    for value in Stances: result.add(%value)
  of "aim":
    for value in Aims: result.add(%value)
  of "posture_bias":
    for value in Postures: result.add(%value)
  of "circle_dir":
    result = %*[-1, 1]
  else:
    let high = case name
      of "bearing_deg": 359
      of "aggression": 10
      of "lead_ticks": 24
      else: raise newException(ValueError, "unknown head: " & name)
    for value in 0 .. high: result.add(%value)

proc heads(): JsonNode =
  result = newJArray()
  for name in ["stance", "aim", "bearing_deg", "aggression",
      "posture_bias", "lead_ticks", "circle_dir"]:
    result.add(%*{"name": name, "choices": choices(name)})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "expected numeric observation")

proc values(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in Variants:
    result.add(%(if variant == name: 1 else: 0))
  for field in ["turn", "of"]:
    result.add(%view[field].number())
  let clock = view["clock"]
  for field in ["tick", "of", "round", "of_rounds", "round_tick",
      "round_of", "round_left_s"]:
    result.add(%clock[field].number())
  let ring = view["ring"]
  for field in ["radius_m", "min_radius_m", "shrink_starts_in_s",
      "radius_at_round_end_m"]:
    result.add(%ring[field].number())
  for actor in ["you", "foe"]:
    let body = view[actor]
    result.add(%body["body"].number())
    for vector in ["pos", "vel"]:
      for value in body[vector]:
        result.add(%value.number())
    for field in ["speed_m_s", "heading_deg", "spin_dps", "effort",
        "reach_m", "tilt_pct", "grounded_legs", "down_ticks",
        "dist_from_centre_m", "dist_to_rim_m"]:
      result.add(%body[field].number())
    if actor == "you":
      for foot in body["feet"]:
        for coordinate in foot:
          result.add(%coordinate.number())
    else:
      for field in ["bearing_from_you_deg", "range_m", "closing_m_s"]:
        result.add(%body[field].number())
  let contact = view["contact"]
  result.add(%(if contact["in_contact"].getBool(): 1 else: 0))
  result.add(%(if contact["normal_deg"].kind == JNull: -1.0
    else: contact["normal_deg"].number()))
  for field in ["your_impulse_last_turn", "their_impulse_last_turn"]:
    result.add(%contact[field].number())
  let match = view["match"]
  for field in ["rounds_won", "knockdowns_this_round", "ring_outs"]:
    for actor in ["you", "foe"]:
      result.add(%match[field][actor].number())
  result.add(%match["to_clinch"].number())
  for index in 0 ..< 5:
    if index < match["round_log"].len:
      let row = match["round_log"][index]
      result.add(%row["round"].number())
      result.add(%(if row["winner"].getStr() == view["you"]["alias"].getStr(): 1
        elif row["winner"].getStr() == view["foe"]["alias"].getStr(): -1
        else: 0))
    else:
      result.add(%(-1))
      result.add(%0)
  let last = view["your_last_intent"]
  result.add(%(if last.kind == JNull: 0 else: 1))
  for field in ["stance", "aim", "posture_bias"]:
    var index = 0
    if last.kind != JNull:
      let options = choices(field)
      for choice in options:
        if choice == last[field]:
          break
        inc index
    result.add(%index)
  for field in ["bearing_deg", "aggression", "lead_ticks", "circle_dir"]:
    result.add(%(if last.kind == JNull: 0.0 else: last[field].number()))

proc action(intent: BugIntent): JsonNode =
  %*{"stance": $intent.stance, "aim": $intent.aim,
    "bearing_deg": intent.bearingDeg, "aggression": intent.aggression,
    "posture_bias": $intent.postureBias, "lead_ticks": intent.leadTicks,
    "circle_dir": intent.circleDir}

proc decision(view: SeatView, id: int): JsonNode =
  let semantic = parseJson(seatViewJson(view))
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{
    "kind": "decision", "game": "physics-bodies",
    "decision_id": id, "seat": view.seat, "engine_seat": view.seat,
    "turn": view.turn, "semantic_view": semantic,
    "inbox": [], "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(OperatorPrompt, $semantic)}
    ], "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()
  }

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: physics-bodies-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var config: GameConfig
  var game: SimServer
  var ctl: ControlState
  var orders: array[BodyCount, BugIntent]
  var haveIntent: array[BodyCount, bool]
  var views: array[BodyCount, SeatView]
  var lastTurn = -1
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == BodyCount
      config = defaultGameConfig()
      let runtime = copy(variantConfig)
      runtime["tokens"] = %*["t0", "t1"]
      config.update($runtime)
      config.seed = seedOf(request["seed"].getStr())
      game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      for index in 0 ..< BodyCount:
        discard game.addPlayer("policy-" & $index, index, "t" & $index)
      while game.phase != Playing:
        game.step([uint8(0), uint8(0)])
      ctl = initControlState()
      haveIntent = default(array[BodyCount, bool])
      for index in 0 ..< BodyCount:
        orders[index] = defaultIntent()
        views[index] = seatView(game, index, false, orders[index])
      lastTurn = game.tickCount div config.turnTicks
      seat = 0
      id = 0
      response = views[seat].decision(id)
    of "encode":
      doAssert game.phase != GameOver
      response = %*{"decision_id": id,
        "values": parseJson(seatViewJson(views[seat])).values(variant),
        "action_heads": heads()}
    of "teacher":
      doAssert game.phase != GameOver
      response = %*{"response": $action(scriptedIntent(ctl.params,
        views[seat], blPusher))}
    of "step":
      doAssert game.phase != GameOver and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      let parsed = parseIntentObject(candidate, orders[seat], haveIntent[seat])
      doAssert action(parsed) == candidate
      orders[seat] = parsed
      haveIntent[seat] = true
      inc id
      inc seat
      var observation: JsonNode
      if seat == BodyCount:
        while game.phase != GameOver:
          var cmds: array[BodyCount, uint8]
          for body in 0 ..< BodyCount:
            let actor = game.seatOfBody(body)
            let intent = if actor >= 0 and haveIntent[actor]:
              orders[actor] else: defaultIntent()
            cmds[game.inputIndexOfBody(body)] =
              driveCommand(ctl, game, body, intent, game.tickCount)
          game.step(cmds)
          let turn = game.tickCount div config.turnTicks
          if game.phase == Playing and game.tickCount mod config.turnTicks == 0 and
              turn != lastTurn:
            lastTurn = turn
            break
        if game.phase == GameOver:
          let outcome = parseJson(game.playerResultsJson())
          var scores = newJObject()
          for actor in 0 ..< BodyCount:
            scores[$actor] = outcome["scores"][actor]
          observation = %*{"kind": "terminal", "scores": scores}
        else:
          seat = 0
          for actor in 0 ..< BodyCount:
            views[actor] = seatView(game, actor, haveIntent[actor], orders[actor])
          observation = views[seat].decision(id)
      else:
        observation = views[seat].decision(id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
