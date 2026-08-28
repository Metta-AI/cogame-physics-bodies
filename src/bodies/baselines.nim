## The per-seat view, and the two published scripted baselines.
##
## `SeatView` is the observation — everything a seat may legitimately know and
## nothing else. The LLM user message is this object rendered as JSON
## (`seatViewJson`), and BOTH baselines are pure functions of the same record,
## so the scripted and prompt policies are strictly comparable.
##
## What a seat does NOT get is the other seat's MIND: its intent object, note,
## say, prompt, latency, policy kind, policy label and fallback state. It sees
## the other BODY's physical state, which is on the board for any spectator to
## read, and withholding that would be a lie about the world.

import std/[json, strutils]
import sim, labels, intents, control

type
  Baseline* = enum
    blPusher = "pusher"
    blAnchor = "anchor"

  SeatView* = object
    seat*, body*, foeBody*: int
    turn*, turns*: int
    tick*, maxTicks*: int
    roundIndex*, maxRounds*, roundTick*, roundTicks*, toClinch*: int
    knockdownsToLose*: int
    ringRadiusUm*, ringRadiusMinUm*, ringRadiusAtEndUm*: int32
    shrinkStartsInTicks*: int
    me*, foe*: Body
    myDistCentreUm*, foeDistCentreUm*: int32
    myDistRimUm*, foeDistRimUm*: int32
    gapUm*: int32
    closingUm*: int32
    inContact*: bool
    contactNormalIdx*: int32
    hasContactNormal*: bool
    myImpulseUm*, foeImpulseUm*: int64
    roundsWonMe*, roundsWonFoe*: int
    ringOutsMe*, ringOutsFoe*: int
    roundLog*: seq[RoundLogEntry]
    hasLast*: bool
    last*: BugIntent

proc parseBaseline*(text: string): Baseline =
  ## A seat that registers with neither field — or never registers at all — is
  ## `pusher`, the certification player and the per-turn fallback.
  case text.strip().toLowerAscii()
  of "anchor": blAnchor
  else: blPusher

proc seatView*(sim: SimServer, seat: int, hasLast: bool,
               last: BugIntent): SeatView =
  ## Builds one seat's observation. Nothing here reads the other seat's policy
  ## state, `perm`, `config.seed`, the RNG, the future start axes or the variant
  ## name (tests/test_observation.nim asserts it over randomised states).
  let
    body = sim.bodyOfSeat(seat)
    bodyIndex = if body < 0: 0 else: body
    foeIndex = 1 - bodyIndex
  result.seat = seat
  result.body = bodyIndex
  result.foeBody = foeIndex
  result.turn = sim.turnIndexAt(sim.tickCount)
  result.turns = sim.turnsPerEpisode()
  result.tick = sim.tickCount
  result.maxTicks = sim.effectiveMaxTicks()
  result.roundIndex = int(sim.roundIndex)
  result.maxRounds = sim.config.maxRounds
  result.roundTick = int(sim.roundTick)
  result.roundTicks = sim.config.roundTicks
  result.toClinch = sim.config.roundsToClinch
  result.knockdownsToLose = sim.config.knockdownsToLose
  result.ringRadiusUm = sim.ringRadiusNow
  result.ringRadiusMinUm = int32(sim.config.ringRadiusMinUm)
  result.ringRadiusAtEndUm = ringRadiusAt(sim.config,
    int32(sim.config.roundTicks))
  result.shrinkStartsInTicks = max(0,
    sim.config.shrinkStartTick - int(sim.roundTick))
  result.me = sim.bodies[bodyIndex]
  result.foe = sim.bodies[foeIndex]
  result.myDistCentreUm = result.me.distFromCentre()
  result.foeDistCentreUm = result.foe.distFromCentre()
  result.myDistRimUm = result.me.distToRim(sim.ringRadiusNow)
  result.foeDistRimUm = result.foe.distToRim(sim.ringRadiusNow)
  result.gapUm = distUm(result.me.px, result.me.py, result.foe.px,
    result.foe.py)
  ## Closing speed: the component of the relative velocity along the line
  ## between the two torso centres, quantised through the committed table so
  ## no trigonometry is needed.
  let toFoe = normalIndexBetween(result.foe.px, result.foe.py,
    result.me.px, result.me.py)
  result.closingUm = int32((
    (int64(result.me.vx) - int64(result.foe.vx)) * int64(dirX(toFoe)) +
    (int64(result.me.vy) - int64(result.foe.vy)) * int64(dirY(toFoe))) div
    int64(Q12))
  result.inContact = result.gapUm <= result.me.contactRangeUm()
  result.hasContactNormal = sim.lastFx.impulseUm > 0 and
    int(sim.lastFx.tick) >= sim.tickCount - int(sim.config.turnTicks)
  result.contactNormalIdx = sim.lastFx.normalIdx
  result.myImpulseUm = result.me.shoveImpulseUm
  result.foeImpulseUm = result.foe.shoveImpulseUm
  result.roundsWonMe = int(sim.roundsWon[bodyIndex])
  result.roundsWonFoe = int(sim.roundsWon[foeIndex])
  result.ringOutsMe = int(sim.ringOuts[bodyIndex])
  result.ringOutsFoe = int(sim.ringOuts[foeIndex])
  result.roundLog = sim.roundLog
  result.hasLast = hasLast
  result.last = last

proc feetJson(b: Body): JsonNode =
  result = newJArray()
  for k in 0 ..< LegCount:
    result.add %[round2(viewX(b.footX[k])), round2(viewY(b.footY[k]))]

proc seatViewJson*(view: SeatView): string =
  ## The observation, in VIEW coordinates (metres, origin bottom-left, y up)
  ## and degrees counter-clockwise from east, every number rounded to 2
  ## decimals. This object is the tail of the LLM user message.
  var node = %*{
    "turn": view.turn, "of": view.turns,
    "clock": {
      "tick": view.tick, "of": view.maxTicks,
      "round": view.roundIndex + 1, "of_rounds": view.maxRounds,
      "round_tick": view.roundTick, "round_of": view.roundTicks,
      "round_left_s": round2(
        float(max(0, view.roundTicks - view.roundTick)) / float(TargetFps))
    },
    "ring": {
      "centre": [round2(viewX(RingCentreX)), round2(viewY(RingCentreY))],
      "radius_m": metres(view.ringRadiusUm),
      "min_radius_m": metres(view.ringRadiusMinUm),
      "shrink_starts_in_s": round2(
        float(view.shrinkStartsInTicks) / float(TargetFps)),
      "radius_at_round_end_m": metres(view.ringRadiusAtEndUm)
    },
    "you": {
      "alias": alias(view.body), "body": view.body,
      "pos": [round2(viewX(view.me.px)), round2(viewY(view.me.py))],
      "vel": [velMs(view.me.vx), velMs(-view.me.vy)],
      "speed_m_s": speedMs(view.me),
      "heading_deg": headingDeg(view.me),
      "spin_dps": spinDps(view.me),
      "posture": $postureOf(view.me.posture()),
      "effort": int(view.me.effort()),
      "reach_m": metres(view.me.reach),
      "tilt_pct": tiltPct(view.me),
      "grounded_legs": int(view.me.groundedCount),
      "down_ticks": int(view.me.downTicks),
      "dist_from_centre_m": metres(view.myDistCentreUm),
      "dist_to_rim_m": metres(view.myDistRimUm),
      "feet": feetJson(view.me)
    },
    "foe": {
      "alias": alias(view.foeBody), "body": view.foeBody,
      "pos": [round2(viewX(view.foe.px)), round2(viewY(view.foe.py))],
      "vel": [velMs(view.foe.vx), velMs(-view.foe.vy)],
      "speed_m_s": speedMs(view.foe),
      "heading_deg": headingDeg(view.foe),
      "spin_dps": spinDps(view.foe),
      "posture": $postureOf(view.foe.posture()),
      "effort": int(view.foe.effort()),
      "reach_m": metres(view.foe.reach),
      "tilt_pct": tiltPct(view.foe),
      "grounded_legs": int(view.foe.groundedCount),
      "down_ticks": int(view.foe.downTicks),
      "dist_from_centre_m": metres(view.foeDistCentreUm),
      "dist_to_rim_m": metres(view.foeDistRimUm),
      "bearing_from_you_deg": bearingFromTo(view.me.px, view.me.py,
        view.foe.px, view.foe.py),
      "range_m": metres(view.gapUm),
      "closing_m_s": velMs(view.closingUm)
    },
    "contact": {
      "in_contact": view.inContact,
      "normal_deg": (
        if view.hasContactNormal: %bearingDegFor(view.contactNormalIdx)
        else: newJNull()),
      "your_impulse_last_turn": round2(float(view.myImpulseUm) / 1_000_000.0),
      "their_impulse_last_turn": round2(float(view.foeImpulseUm) / 1_000_000.0)
    },
    "match": {
      "rounds_won": {"you": view.roundsWonMe, "foe": view.roundsWonFoe},
      "to_clinch": view.toClinch,
      "knockdowns_this_round": {
        "you": int(view.me.knockdowns), "foe": int(view.foe.knockdowns)},
      "ring_outs": {"you": view.ringOutsMe, "foe": view.ringOutsFoe},
      "round_log": newJArray()
    },
    "rules": {
      "knockdowns_to_lose": view.knockdownsToLose,
      "round_win_points": 1.0,
      "ring_out_bonus": 0.25,
      "knockout_bonus": 0.25,
      "zero_sum": true,
      "note": "a leg whose foot is over the rim has no floor: no push, no " &
        "balance recovery"
    }
  }
  for entry in view.roundLog:
    node["match"]["round_log"].add %*{
      "round": int(entry.round),
      "winner": (if entry.winner < 0: "draw" else: alias(int(entry.winner))),
      "reason": $entry.reason
    }
  if view.hasLast:
    node["your_last_intent"] = %*{
      "stance": $view.last.stance,
      "aim": $view.last.aim,
      "bearing_deg": view.last.bearingDeg,
      "aggression": view.last.aggression,
      "posture_bias": $view.last.postureBias,
      "lead_ticks": view.last.leadTicks,
      "circle_dir": view.last.circleDir
    }
  else:
    node["your_last_intent"] = newJNull()
  $node

# ---------------------------------------------------------------------------
#  pusher — the certification player, the per-turn fallback, and the default
# ---------------------------------------------------------------------------

proc pusherIntent*(params: BaselineParams, view: SeatView): BugIntent =
  result = defaultIntent()
  result.source = isScripted
  if view.me.downTicks > 0 or view.me.tipMilli > 700:
    result.stance = stanceBrace
    result.postureBias = biasLow
    result.aggression = 2
    result.say = "getting my feet back"
  elif int(view.myDistRimUm) < params.rimGuardUm:
    result.stance = stanceRetreat
    result.aim = aimCentre
    result.aggression = 6
    result.say = "off the edge"
  elif view.inContact and view.foeDistRimUm < view.myDistRimUm:
    result.stance = stanceCharge
    result.aim = aimFoe
    result.aggression = 10
    result.postureBias = biasAuto
    result.leadTicks = 2
    result.say = "walking it out"
  elif view.inContact:
    result.stance = stanceLift
    result.aggression = 8
    result.leadTicks = 0
    result.say = "under it"
  elif int(view.gapUm) > params.liftEngageUm * 2:
    result.stance = stanceCharge
    result.aim = aimFoe
    result.aggression = 8
    result.leadTicks = params.chargeLeadTicks
    result.say = "closing"
  else:
    result.stance = stanceCharge
    result.aim = aimFoe
    result.aggression = 9
    result.leadTicks = 2
    result.say = "closing"
  result.note = "pusher: " & $result.stance & " at " & $result.aggression

# ---------------------------------------------------------------------------
#  anchor — the second filler, deliberately different in shape and weaker
# ---------------------------------------------------------------------------

proc anchorIntent*(params: BaselineParams, view: SeatView): BugIntent =
  ## It never initiates: it wins decisions and loses to sustained pressure,
  ## which gives the ladder a spread and a champion a stubborn opponent.
  result = defaultIntent()
  result.source = isScripted
  if view.myDistCentreUm > 500_000:
    result.stance = stanceCentre
    result.aim = aimCentre
    result.aggression = 5
    result.say = "middle is mine"
  elif view.inContact:
    result.stance = stanceBrace
    result.postureBias = biasLow
    result.aggression = 7
    result.say = "spend it on me"
  elif view.gapUm < 1_500_000:
    result.stance = stanceBrace
    result.postureBias = biasLow
    result.aggression = 4
    result.say = "spend it on me"
  else:
    result.stance = stanceCircle
    result.circleDir = if (view.roundIndex mod 2) == 1: -1 else: 1
    result.aggression = 3
    result.postureBias = biasEven
    result.say = "after you"
  result.note = "anchor: " & $result.stance & " at " & $result.aggression

proc scriptedIntent*(params: BaselineParams, view: SeatView,
                     kind: Baseline): BugIntent =
  case kind
  of blPusher: pusherIntent(params, view)
  of blAnchor: anchorIntent(params, view)
