## Shared test helpers: the ONE episode harness every suite drives, so no test
## can accidentally exercise a control path the server does not.
##
## It is deliberately the server's own path in miniature: build the observation,
## compile the intent through `scriptedIntent`, compile the byte through
## `driveCommand`, write the byte with `writeInputMaskChange`, step, hash.

import std/[json, os, random, strutils]
import bodies/[sim, global, broadcast, intents, control, baselines, replays]

type
  EpisodeResult* = object
    sim*: SimServer
    replayPath*: string
    ticks*: int

proc certConfig*(seed = 5104773): GameConfig =
  ## The CERTIFICATION FIXTURE's config, exactly as
  ## `coworld_manifest_template.json` declares it.
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = 1728
  result.maxRounds = 4
  result.roundsToClinch = 4
  result.maxGames = 1
  result.turnTicks = 36
  result.turnBudgetMs = 16000
  result.turnSpacingMs = 0
  result.wallClockBudgetSeconds = 180
  result.lobbyJoinTimeoutTicks = 480
  result.ringShrinkPerTickUm = 0
  result.fastMode = true
  result.players = @[PlayerConfig(name: "BUG-1"), PlayerConfig(name: "BUG-2")]

proc defaultMatchConfig*(seed = 5104773): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.turnSpacingMs = 0

proc runEpisode*(config: GameConfig,
                 kinds: array[BodyCount, Baseline] = [blPusher, blPusher],
                 replayPath = "", names: array[BodyCount, string] =
                   ["BUG-1", "BUG-2"], maxTicks = 5000,
                 sayOverride = "", labelOverride = "",
                 seatsJoined = BodyCount): EpisodeResult =
  ## Plays one full scripted episode through the server's control path and,
  ## when `replayPath` is set, records a `COWLDPBD` replay for it.
  ##
  ## `seatsJoined` < BodyCount is the NO-SHOW case: the lobby budget expires,
  ## the round starts anyway and the missing seat's bug is driven by the
  ## scripted layer for the whole run (§End conditions). Every seat still gets
  ## an intent, exactly as `decide.turn` gives one to every seat of
  ## `sim.seatCount()` whether or not a player is behind it.
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var ctl = initControlState()
  var writer =
    if replayPath.len > 0: openReplayWriter(replayPath,
      config.configJson(sim.perm))
    else: ReplayWriter()
  for seat in 0 ..< min(seatsJoined, sim.seatCount()):
    discard sim.addPlayer(names[seat], seat, "")
    if replayPath.len > 0:
      writer.writeJoin(tickTime(sim.tickCount), seat, names[seat], seat, "")
    sim.seatPolicyKind[seat] = "scripted"
    if replayPath.len > 0:
      writer.writeChat(tickTime(sim.tickCount), seat,
        registerRecord(seat, sim.bodyOfSeat(seat),
          (if labelOverride.len > 0: labelOverride else: $kinds[seat]),
          "scripted", $kinds[seat]))
  var
    cmds = newSeq[uint8](BodyCount)
    lastIntent: array[BodyCount, BugIntent]
    haveIntent: array[BodyCount, bool]
    lastTurn = -1
    roundsRecorded = 0
  for i in 0 ..< BodyCount:
    lastIntent[i] = defaultIntent()
  while sim.phase != GameOver and sim.tickCount < maxTicks:
    if sim.phase == Playing:
      let turn = sim.tickCount div max(1, config.turnTicks)
      if sim.tickCount mod max(1, config.turnTicks) == 0 and turn != lastTurn:
        lastTurn = turn
        for seat in 0 ..< sim.seatCount():
          let view = seatView(sim, seat, haveIntent[seat], lastIntent[seat])
          var intent = scriptedIntent(ctl.params, view, kinds[seat])
          if sayOverride.len > 0:
            intent.say = sanitizeSay(sayOverride)
            intent.note = sayOverride
          lastIntent[seat] = intent
          haveIntent[seat] = true
          inc sim.llmTurns[seat]
          if replayPath.len > 0:
            let record = boundedIntentRecord(intent, turn, seat,
              sim.bodyOfSeat(seat))
            writer.writeChat(tickTime(sim.tickCount), seat, record)
            sim.pushFeedIntent(record)
    for i in 0 ..< BodyCount:
      let seat = sim.seatOfBody(i)
      let intent =
        if seat >= 0 and haveIntent[seat]: lastIntent[seat]
        else: defaultIntent()
      let
        cmd = driveCommand(ctl, sim, i, intent, sim.tickCount)
        row = sim.inputIndexOfBody(i)
      cmds[row] = cmd
      if replayPath.len > 0:
        writer.writeInputMaskChange(tickTime(sim.tickCount), row, cmd)
    sim.step(cmds)
    if replayPath.len > 0:
      writer.writeHash(uint32(sim.tickCount), sim.gameHash())
      ## Each `round` record on the tick its round ENDED, exactly as the server
      ## writes them (server.nim `flushRoundRecords`).
      while roundsRecorded < sim.roundLog.len:
        let entry = sim.roundLog[roundsRecorded]
        writer.writeChat(tickTime(sim.tickCount), 0,
          roundRecord(int(entry.round), int(entry.winner), $entry.reason,
            int(entry.ticks), entry.knockdowns))
        inc roundsRecorded
  if replayPath.len > 0:
    writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
    writer.closeReplayWriter()
  result.sim = sim
  result.replayPath = replayPath
  result.ticks = sim.tickCount

proc tempPath*(name: string): string =
  getTempDir() / ("physics-bodies-test-" & $getCurrentProcessId() & "-" & name)

proc randomBody*(rng: var Rand, ringRadius: int32): Body =
  ## A random LEGAL up-state: the torso centre is inside the ring (that is what
  ## "up" means), so `groundedCount` is in 1..4 by construction.
  let
    angle = rng.rand(0 .. 31)
    radius = rng.rand(0 .. int(ringRadius) - 1)
  result.px = RingCentreX +
    int32((int64(radius) * int64(dirX(int32(angle)))) div int64(Q12))
  result.py = RingCentreY +
    int32((int64(radius) * int64(dirY(int32(angle)))) div int64(Q12))
  result.vx = int32(rng.rand(-120_000 .. 120_000))
  result.vy = int32(rng.rand(-120_000 .. 120_000))
  result.hMilli = int32(rng.rand(0 .. 31_999))
  result.omegaMilli = int32(rng.rand(-int(MaxYawMilli) .. int(MaxYawMilli)))
  result.tipMilli = int32(rng.rand(0 .. int(TipDown)))
  result.lastCmd = uint8(rng.rand(0 .. 255))
  result.refreshLegs(RingCentreX, RingCentreY, ringRadius)

proc chromeFrame*(sim: var SimServer): JsonNode =
  ## The chrome frame this sim would emit, parsed. Every viewer/observation test
  ## reads it through here so none of them hand-builds the shape.
  parseJson(sim.buildStateJson(newJArray(), true, 1, sim.tickCount, false,
    true, -1))

proc repoFile*(relative: string): string =
  ## Test files run from the repo root (CI's `nim r --path:src tests/x.nim`).
  for candidate in [relative, ".." / relative]:
    if fileExists(candidate):
      return candidate
  relative
