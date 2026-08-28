## Regenerates tests/data/golden_hashes.json — the committed hash fixture the
## determinism gate compares against.
##
##   nim c -d:release --path:src -r tools/gen_golden_hashes.nim \
##     > tests/data/golden_hashes.json
##
## Re-record it ONLY when GameVersion is bumped for a real rule change. A
## mismatch on an unchanged version means the physics moved by accident, which
## is exactly what the fixture exists to catch.

import std/json
import bodies/[sim, intents, control, baselines]

const Interval = 48

when isMainModule:
  var cfg = defaultGameConfig()
  cfg.seed = 5104773
  cfg.turnSpacingMs = 0
  var game = initSimServer(cfg)
  game.gameEventLoggingEnabled = false
  var ctl = initControlState()
  for seat in 0 ..< game.seatCount():
    discard game.addPlayer("seat-" & $seat, seat, "")
  var
    cmds = newSeq[uint8](BodyCount)
    lastIntent: array[BodyCount, BugIntent]
    haveIntent: array[BodyCount, bool]
    lastTurn = -1
    rows = newJArray()
  for i in 0 ..< BodyCount:
    lastIntent[i] = defaultIntent()
  while game.tickCount < cfg.maxTicks and game.phase != GameOver:
    if game.phase == Playing:
      let turn = game.tickCount div cfg.turnTicks
      if game.tickCount mod cfg.turnTicks == 0 and turn != lastTurn:
        lastTurn = turn
        for seat in 0 ..< game.seatCount():
          lastIntent[seat] = scriptedIntent(ctl.params,
            seatView(game, seat, haveIntent[seat], lastIntent[seat]), blPusher)
          haveIntent[seat] = true
    for i in 0 ..< BodyCount:
      let seat = game.seatOfBody(i)
      let intent =
        if seat >= 0 and haveIntent[seat]: lastIntent[seat]
        else: defaultIntent()
      cmds[game.inputIndexOfBody(i)] =
        driveCommand(ctl, game, i, intent, game.tickCount)
    game.step(cmds)
    if game.tickCount mod Interval == 0:
      rows.add %*{"tick": game.tickCount, "hash": $game.gameHash()}
  echo (%*{
    "seed": cfg.seed,
    "gameVersion": GameVersion,
    "interval": Interval,
    "finalTick": game.tickCount,
    "hashes": rows
  }).pretty()
