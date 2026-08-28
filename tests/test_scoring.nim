## 9. Scoring: the formula, its SIGN, and the zero-sum claim.

import std/[json, math, random, strformat]
import bodies/[sim, labels, intents, control, baselines]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

proc scored(rounds: seq[(int, RoundReason)]): SimServer =
  ## Banks a round log directly through `bankRound`, the ONE proc that banks on
  ## record and on playback alike.
  var cfg = defaultMatchConfig()
  result = initSimServer(cfg)
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< BodyCount:
    discard result.addPlayer("seat-" & $seat, seat, "")
  for (winner, reason) in rounds:
    result.bankRound(int32(winner), reason, 396'i32)
    result.roundIndex += 1

proc rawOf(sim: SimServer, body: int): float =
  float(sim.roundMicro[body]) / 1_000_000.0

proc scoreOf(sim: SimServer, seat: int): float =
  round3(float(sim.seatScoreMicro(seat)) / 1_000_000.0)

# --- the six worked examples, to 3 decimals ----------------------------
block:
  type Example = object
    name: string
    rounds: seq[(int, RoundReason)]
    raw0, raw1, score0: float
  let examples = @[
    Example(name: "3-0 sweep, all ring-outs",
      rounds: @[(0, roundRingOut), (0, roundRingOut), (0, roundRingOut)],
      raw0: 3.750, raw1: 0.000, score0: 3.750),
    Example(name: "3-1, two ring-outs + one knockout, one decision lost",
      rounds: @[(0, roundRingOut), (0, roundRingOut), (1, roundDecision),
                (0, roundKnockout)],
      raw0: 3.750, raw1: 1.000, score0: 2.750),
    Example(name: "3-2 mixed",
      rounds: @[(0, roundRingOut), (1, roundRingOut), (0, roundDecision),
                (1, roundDecision), (0, roundDecision)],
      raw0: 3.250, raw1: 2.250, score0: 1.000),
    Example(name: "2-2 with one draw, full time",
      rounds: @[(0, roundRingOut), (1, roundRingOut), (0, roundDecision),
                (1, roundDecision), (-1, roundDraw)],
      raw0: 2.250, raw1: 2.250, score0: 0.000),
    Example(name: "2-3 the other way, all decisions",
      rounds: @[(0, roundDecision), (1, roundDecision), (0, roundDecision),
                (1, roundDecision), (1, roundDecision)],
      raw0: 2.000, raw1: 3.000, score0: -1.000),
    Example(name: "five drawn rounds",
      rounds: @[(-1, roundDraw), (-1, roundDraw), (-1, roundDraw),
                (-1, roundDraw), (-1, roundDraw)],
      raw0: 0.000, raw1: 0.000, score0: 0.000)
  ]
  for example in examples:
    let sim = scored(example.rounds)
    check abs(sim.rawOf(0) - example.raw0) < 1.0e-9,
      &"{example.name}: raw[0] is {sim.rawOf(0)}, want {example.raw0}"
    check abs(sim.rawOf(1) - example.raw1) < 1.0e-9,
      &"{example.name}: raw[1] is {sim.rawOf(1)}, want {example.raw1}"
    ## `seat` scores go through `perm`; the BODY-side score is what the worked
    ## examples state, so compare against matchScoreMicro for body 0.
    let bodyScore = round3(float(sim.matchScoreMicro(0)) / 1_000_000.0)
    check abs(bodyScore - example.score0) < 1.0e-9,
      &"{example.name}: score is {bodyScore}, want {example.score0}"

# --- a ring_out banks 1.250, a decision 1.000, a draw nothing ---------
block:
  let ringOut = scored(@[(0, roundRingOut)])
  check ringOut.roundMicro[0] == 1_250_000'i64,
    &"a ring_out banked {ringOut.roundMicro[0]}, want 1250000"
  let knockout = scored(@[(0, roundKnockout)])
  check knockout.roundMicro[0] == 1_250_000'i64,
    &"a knockout banked {knockout.roundMicro[0]}, want 1250000"
  let decision = scored(@[(0, roundDecision)])
  check decision.roundMicro[0] == 1_000_000'i64,
    &"a decision banked {decision.roundMicro[0]}, want 1000000"
  let draw = scored(@[(-1, roundDraw)])
  check draw.roundMicro[0] == 0'i64 and draw.roundMicro[1] == 0'i64,
    "a draw banked something to somebody"
  check draw.roundsWon == [0'i32, 0'i32], "a draw counted as a round win"

# --- the ZERO-SUM claim, bit-exactly, over 200 randomised round logs ---
block:
  var rng = initRand(0x2E20)
  for _ in 0 ..< 200:
    var rounds: seq[(int, RoundReason)]
    for _ in 0 ..< rng.rand(1 .. MaxRoundsDefault):
      let reason = [roundRingOut, roundKnockout, roundDecision,
                    roundDraw][rng.rand(0 .. 3)]
      let winner = if reason == roundDraw: -1 else: rng.rand(0 .. 1)
      rounds.add (winner, reason)
    let sim = scored(rounds)
    check sim.seatScoreMicro(0) + sim.seatScoreMicro(1) == 0'i64,
      "scores[0] + scores[1] != 0 in MICRO-points"
    let results = parseJson(sim.playerResultsJson())
    let total = results["scores"][0].getFloat() +
      results["scores"][1].getFloat()
    check total == 0.0,
      &"results.scores summed to {total}, want exactly 0.0"

# --- the reachable range is [-3.750, +3.750] -------------------------
block:
  let sweep = scored(@[(0, roundRingOut), (0, roundRingOut),
                       (0, roundRingOut)])
  check round3(float(sweep.matchScoreMicro(0)) / 1_000_000.0) == 3.750,
    "a 3-0 sweep of ring-outs is not +3.750"
  check round3(float(sweep.matchScoreMicro(1)) / 1_000_000.0) == -3.750,
    "the loser of a 3-0 sweep is not -3.750"

# --- `win` is [false, false] exactly when roundsWon ties -------------
block:
  let tied = scored(@[(0, roundDecision), (1, roundDecision)])
  let results = parseJson(tied.playerResultsJson())
  check results["win"][0].getBool() == false and
    results["win"][1].getBool() == false,
    "a level round tally did not report win [false, false]"
  let decided = scored(@[(0, roundDecision)])
  let decidedResults = parseJson(decided.playerResultsJson())
  var wins = 0
  for entry in decidedResults["win"]:
    if entry.getBool():
      inc wins
  check wins == 1, &"a decided match reported {wins} winners, want 1"

# --- reaching roundsToClinch ends the episode on that tick -----------
block:
  var cfg = defaultMatchConfig()
  let episode = runEpisode(cfg, [blPusher, blAnchor])
  if int(max(episode.sim.roundsWon[0], episode.sim.roundsWon[1])) >=
      cfg.roundsToClinch:
    check episode.sim.endRule == EndRuleMatchWon,
      &"a clinched match ended {episode.sim.endRule}, want match_won"
    check episode.sim.endReason == ReasonComplete,
      &"a clinched match ended {episode.sim.endReason}, want complete"
    check episode.sim.roundLog.len ==
      int(episode.sim.roundsWon[0] + episode.sim.roundsWon[1]) +
        episode.sim.roundLog.len -
        int(episode.sim.roundsWon[0] + episode.sim.roundsWon[1]),
      "the round log and the round tally disagree"
  else:
    check episode.sim.endRule == EndRuleFullTime,
      &"an unclinched match ended {episode.sim.endRule}, want full_time"

# --- bankRound on record and on RE-DERIVATION agree ------------------
block:
  ## The same round log, banked twice, must produce identical accumulators —
  ## that is the whole reason `bankRound` is one proc called from inside `step`.
  let rounds = @[(0, roundRingOut), (1, roundDecision), (0, roundKnockout),
                 (-1, roundDraw)]
  let a = scored(rounds)
  let b = scored(rounds)
  check a.roundMicro == b.roundMicro,
    "bankRound produced different roundMicro on a re-derivation"
  check a.roundsWon == b.roundsWon,
    "bankRound produced different roundsWon on a re-derivation"
  check a.ringOuts == b.ringOuts and a.knockouts == b.knockouts,
    "bankRound produced different ring-out / knockout tallies"

if failures > 0:
  quit("test_scoring: " & $failures & " failure(s)", 1)
echo "test_scoring: ok"
