## GameConfig lifecycle: the defaults, the tolerant `update` the platform's
## resolved config JSON goes through, and the `configJson` the replay header
## pins so playback never re-derives anything.
##
## Every field here appears in `coworld_manifest_template.json`'s
## `game.config_schema` and nowhere else is settable — tests/test_manifest.nim
## asserts the schema covers exactly what this file reads.

import std/[json, strutils]
import sim_types

proc defaultGameConfig*(): GameConfig =
  result.tokens = @[]
  result.players = @[]
  result.slots = @[
    SlotConfig(alias: BugAliases[0]),
    SlotConfig(alias: BugAliases[1])
  ]
  result.closedRoster = false
  result.seed = 0
  result.numAgents = BodyCount
  result.minPlayers = BodyCount
  result.maxTicks = MaxTicksDefault
  result.maxGames = 1
  result.turnTicks = TurnTicksDefault
  result.roundTicks = RoundTicksDefault
  result.resetTicks = ResetTicksDefault
  result.maxRounds = MaxRoundsDefault
  result.roundsToClinch = RoundsToClinchDefault
  result.ringRadiusUm = int(RingRadius0)
  result.ringRadiusMinUm = int(RingRadiusMin)
  result.ringShrinkPerTickUm = int(ShrinkPerTick)
  result.shrinkStartTick = int(ShrinkStartTick)
  result.knockdownsToLose = int(KnockdownsToLoseDefault)
  result.downTicks = int(DownTicksDefault)
  result.turnBudgetMs = TurnBudgetMsDefault
  result.attempt1Ms = Attempt1MsDefault
  result.retryMs = RetryMsDefault
  result.turnSpacingMs = TurnSpacingMsDefault
  result.wallClockBudgetSeconds = WallClockBudgetSecondsDefault
  result.lobbyJoinTimeoutTicks = LobbyJoinTimeoutTicksDefault
  result.startWaitTicks = StartWaitTicksDefault
  result.gameOverTicks = GameOverTicksDefault
  result.fastMode = true
  result.showPlayerLabels = false
  result.model = ""
  result.maxOutputTokens = MaxOutputTokensDefault
  result.speed = 1

proc readInt(node: JsonNode, key: string, current: int): int =
  let value = node{key}
  if value.isNil:
    return current
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: parseInt(value.getStr().strip())
    except CatchableError: current
  else: current

proc readBool(node: JsonNode, key: string, current: bool): bool =
  let value = node{key}
  if value.isNil:
    return current
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  of JString: value.getStr().strip().toLowerAscii() in ["1", "true", "yes", "on"]
  else: current

proc readString(node: JsonNode, key, current: string): string =
  let value = node{key}
  if value.isNil or value.kind != JString:
    return current
  value.getStr()

proc validate(config: var GameConfig) =
  ## Bounds every field the sim divides by, indexes with, or waits on. A
  ## config that would make the loop hang or the wall clock unbounded is
  ## refused here, at the one place it can still be refused cleanly.
  config.numAgents = clamp(config.numAgents, 1, BodyCount)
  config.minPlayers = clamp(config.minPlayers, 1, config.numAgents)
  config.turnTicks = clamp(config.turnTicks, 1, 6000)
  config.roundTicks = clamp(config.roundTicks, config.turnTicks, 100_000)
  config.resetTicks = clamp(config.resetTicks, 0, 6000)
  config.maxRounds = clamp(config.maxRounds, 1, MaxRoundsDefault)
  config.roundsToClinch = clamp(config.roundsToClinch, 1, config.maxRounds)
  config.maxGames = clamp(config.maxGames, 1, 4)
  config.maxTicks = clamp(config.maxTicks, config.turnTicks, 1_000_000)
  config.ringRadiusUm = clamp(config.ringRadiusUm, 600_000,
    int(min(ArenaW, ArenaH) div 2))
  config.ringRadiusMinUm = clamp(config.ringRadiusMinUm, 400_000,
    config.ringRadiusUm)
  config.ringShrinkPerTickUm = clamp(config.ringShrinkPerTickUm, 0, 100_000)
  config.shrinkStartTick = clamp(config.shrinkStartTick, 0, config.roundTicks)
  config.knockdownsToLose = clamp(config.knockdownsToLose, 1, 99)
  config.downTicks = clamp(config.downTicks, 1, 600)
  ## curly hands the batch deadline to CURLOPT_TIMEOUT, whose granularity is
  ## WHOLE SECONDS and whose conversion FLOORS — a sub-second value is not the
  ## deadline it claims to be, so it is refused rather than silently floored
  ## to zero (paintbot 0.1.2's scar: `attempt1Ms: 4500` really ran with 4 s).
  config.attempt1Ms = clamp(config.attempt1Ms, 1000, 120_000)
  config.retryMs = clamp(config.retryMs, 1000, 120_000)
  config.turnBudgetMs = clamp(config.turnBudgetMs,
    config.attempt1Ms + config.retryMs, 240_000)
  config.turnSpacingMs = clamp(config.turnSpacingMs, 0, 120_000)
  config.wallClockBudgetSeconds = clamp(config.wallClockBudgetSeconds, 10, 720)
  config.lobbyJoinTimeoutTicks = clamp(config.lobbyJoinTimeoutTicks, 24, 20_000)
  config.startWaitTicks = clamp(config.startWaitTicks, 0, 20_000)
  config.gameOverTicks = clamp(config.gameOverTicks, 0, 20_000)
  config.maxOutputTokens = clamp(config.maxOutputTokens, 64, 8192)
  config.speed = clamp(config.speed, 1, PlaybackSpeeds[^1])
  while config.slots.len < BodyCount:
    config.slots.add SlotConfig(alias: BugAliases[config.slots.len])
  for i in 0 ..< config.slots.len:
    if config.slots[i].alias.len == 0 and i < BodyCount:
      config.slots[i].alias = BugAliases[i]

proc update*(config: var GameConfig, configJson: string) =
  ## Folds one resolved config document into this config. Unknown keys are
  ## ignored (the CLI already validated them against `config_schema`); a
  ## malformed document raises so the entrypoint can exit with a clean message
  ## rather than play a game nobody asked for.
  if configJson.strip().len == 0:
    config.validate()
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(BodiesError,
      "game config is not valid JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(BodiesError, "game config must be a JSON object")

  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      if item.kind == JString:
        config.tokens.add item.getStr()

  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.players = @[]
    for item in players:
      if item.kind == JObject:
        config.players.add PlayerConfig(name: item{"name"}.getStr())
      elif item.kind == JString:
        config.players.add PlayerConfig(name: item.getStr())

  let slots = node{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for i, item in slots.getElems():
      var slot = SlotConfig(
        alias: (if i < BodyCount: BugAliases[i] else: "BUG-?"))
      if item.kind == JObject:
        let
          aliasNode = item{"alias"}
          tokenNode = item{"token"}
        if not aliasNode.isNil and aliasNode.kind == JString and
            aliasNode.getStr().len > 0:
          slot.alias = aliasNode.getStr()
        if not tokenNode.isNil and tokenNode.kind == JString:
          slot.token = tokenNode.getStr()
      config.slots.add slot

  ## `tokens` are injected by the runner and are the authoritative per-slot
  ## secret; a slot that carries none takes the injected token by position.
  for i in 0 ..< config.slots.len:
    if config.slots[i].token.len == 0 and i < config.tokens.len:
      config.slots[i].token = config.tokens[i]

  config.closedRoster = readBool(node, "closedRoster", config.closedRoster)
  config.seed = readInt(node, "seed", config.seed)
  config.numAgents = readInt(node, "num_agents",
    readInt(node, "numAgents", config.numAgents))
  config.minPlayers = readInt(node, "minPlayers", config.minPlayers)
  config.maxTicks = readInt(node, "maxTicks", config.maxTicks)
  config.maxGames = readInt(node, "maxGames", config.maxGames)
  config.turnTicks = readInt(node, "turnTicks", config.turnTicks)
  config.roundTicks = readInt(node, "roundTicks", config.roundTicks)
  config.resetTicks = readInt(node, "resetTicks", config.resetTicks)
  config.maxRounds = readInt(node, "maxRounds", config.maxRounds)
  config.roundsToClinch = readInt(node, "roundsToClinch", config.roundsToClinch)
  config.ringRadiusUm = readInt(node, "ringRadiusUm", config.ringRadiusUm)
  config.ringRadiusMinUm = readInt(node, "ringRadiusMinUm",
    config.ringRadiusMinUm)
  config.ringShrinkPerTickUm = readInt(node, "ringShrinkPerTickUm",
    config.ringShrinkPerTickUm)
  config.shrinkStartTick = readInt(node, "shrinkStartTick",
    config.shrinkStartTick)
  config.knockdownsToLose = readInt(node, "knockdownsToLose",
    config.knockdownsToLose)
  config.downTicks = readInt(node, "downTicks", config.downTicks)
  config.turnBudgetMs = readInt(node, "turnBudgetMs", config.turnBudgetMs)
  config.attempt1Ms = readInt(node, "attempt1Ms", config.attempt1Ms)
  config.retryMs = readInt(node, "retryMs", config.retryMs)
  config.turnSpacingMs = readInt(node, "turnSpacingMs", config.turnSpacingMs)
  config.wallClockBudgetSeconds = readInt(node, "wallClockBudgetSeconds",
    config.wallClockBudgetSeconds)
  config.lobbyJoinTimeoutTicks = readInt(node, "lobbyJoinTimeoutTicks",
    config.lobbyJoinTimeoutTicks)
  config.startWaitTicks = readInt(node, "startWaitTicks", config.startWaitTicks)
  config.gameOverTicks = readInt(node, "gameOverTicks", config.gameOverTicks)
  config.fastMode = readBool(node, "fastMode", config.fastMode)
  config.showPlayerLabels = readBool(node, "showPlayerLabels",
    config.showPlayerLabels)
  config.model = readString(node, "model", config.model)
  config.maxOutputTokens = readInt(node, "maxOutputTokens",
    config.maxOutputTokens)
  config.speed = readInt(node, "speed", config.speed)
  config.validate()

proc geometryJson*(config: GameConfig): JsonNode =
  ## The whole geometry and actuation table, pinned into the replay so playback
  ## never re-derives a constant this build happened to change.
  %*{
    "arenaW": ArenaW, "arenaH": ArenaH,
    "ringCentre": [RingCentreX, RingCentreY],
    "ringRadiusUm": config.ringRadiusUm,
    "ringRadiusMinUm": config.ringRadiusMinUm,
    "ringShrinkPerTickUm": config.ringShrinkPerTickUm,
    "shrinkStartTick": config.shrinkStartTick,
    "torsoRadius": TorsoRadius, "footRadius": FootRadius,
    "startRadius": StartRadius,
    "legBaseIdx": [LegBaseIdx[0], LegBaseIdx[1], LegBaseIdx[2], LegBaseIdx[3]],
    "reachByPosture": [ReachByPosture[0], ReachByPosture[1],
                       ReachByPosture[2], ReachByPosture[3]],
    "thrustUnit": ThrustUnit,
    "tractionMulPct": [TractionMulPct[0], TractionMulPct[1],
                       TractionMulPct[2], TractionMulPct[3]],
    "fricNumPer1024": [FricNumPer1024[0], FricNumPer1024[1],
                       FricNumPer1024[2], FricNumPer1024[3]],
    "maxSpeedByPosture": [MaxSpeedByPosture[0], MaxSpeedByPosture[1],
                          MaxSpeedByPosture[2], MaxSpeedByPosture[3]],
    "maxBodySpeedHard": MaxBodySpeedHard,
    "yawGainPct": [YawGainPct[0], YawGainPct[1], YawGainPct[2], YawGainPct[3]],
    "yawAccelMilli": YawAccelMilli, "maxYawMilli": MaxYawMilli,
    "yawDragNumPer1024": YawDragNumPer1024,
    "restitution": Restitution, "shoveUnit": ShoveUnit,
    "shoveMulPct": [ShoveMulPct[0], ShoveMulPct[1], ShoveMulPct[2],
                    ShoveMulPct[3]],
    "tipImpulseThreshUm": TipImpulseThreshUm, "tipPerUmDiv": TipPerUmDiv,
    "liftTipMilli": LiftTipMilli, "liftSelfTipMilli": LiftSelfTipMilli,
    "tipRecvMulPct": [TipRecvMulPct[0], TipRecvMulPct[1], TipRecvMulPct[2],
                      TipRecvMulPct[3]],
    "spinTipMilli": SpinTipMilli, "tipRecoverMilli": TipRecoverMilli,
    "tipDown": TipDown, "centreTieUm": CentreTieUm,
    "roundWinMicro": RoundWinMicro,
    "ringOutBonusMicro": RingOutBonusMicro,
    "knockoutBonusMicro": KnockoutBonusMicro
  }

proc configJson*(config: GameConfig, perm: array[BodyCount, int32]): string =
  ## The resolved config document written into the replay header. It carries
  ## the seed, `perm` (the viewer needs it to map REAL names onto bodies), the
  ## whole geometry table and the roster's real names.
  var players = newJArray()
  for player in config.players:
    players.add %*{"name": player.name}
  var slots = newJArray()
  for slot in config.slots:
    slots.add %*{"alias": slot.alias}
  var permJson = newJArray()
  for value in perm:
    permJson.add %value
  $(%*{
    "gameName": GameName,
    "gameVersion": GameVersion,
    "seed": config.seed,
    "perm": permJson,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "turnTicks": config.turnTicks,
    "roundTicks": config.roundTicks,
    "resetTicks": config.resetTicks,
    "maxRounds": config.maxRounds,
    "roundsToClinch": config.roundsToClinch,
    "knockdownsToLose": config.knockdownsToLose,
    "downTicks": config.downTicks,
    # EVERY field `update` reads is pinned at TOP LEVEL under its
    # `config_schema` name: playback re-reads the config through the same
    # `update`, so a field that lived only inside the `geometry` block would
    # silently fall back to this build's default and diverge the hash chain
    # the moment it differed (the ring shrink law is exactly that hazard).
    "ringRadiusUm": config.ringRadiusUm,
    "ringRadiusMinUm": config.ringRadiusMinUm,
    "ringShrinkPerTickUm": config.ringShrinkPerTickUm,
    "shrinkStartTick": config.shrinkStartTick,
    "closedRoster": config.closedRoster,
    "speed": config.speed,
    "model": config.model,
    "maxOutputTokens": config.maxOutputTokens,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnSpacingMs": config.turnSpacingMs,
    "geometry": config.geometryJson(),
    "players": players,
    "slots": slots
  })

proc configuredPlayerName*(config: GameConfig, slot: int,
                           token: string): string =
  ## The real policy name configured for one slot, resolved by slot index
  ## first and by matching token second (the runner may hand a seat only its
  ## token).
  if slot >= 0 and slot < config.players.len and
      config.players[slot].name.len > 0:
    return config.players[slot].name
  if token.len > 0:
    for i in 0 ..< config.slots.len:
      if config.slots[i].token.len > 0 and config.slots[i].token == token and
          i < config.players.len:
        return config.players[i].name
  ""

proc playerJoinAllowed*(config: GameConfig, address: string, slot: int,
                        token: string): bool =
  ## Whether one websocket may seat itself. A slot with a configured token
  ## demands exactly that token — the certifier probes `?slot=0&token=bad` and
  ## a server that accepts it fails cert `smoke-episode` (cogame-flatland
  ## 0.1.1).
  if slot >= MaxPlayers:
    return false
  if slot >= 0 and slot < config.slots.len and
      config.slots[slot].token.len > 0:
    return token == config.slots[slot].token
  if config.closedRoster and slot >= config.slots.len:
    return false
  true
