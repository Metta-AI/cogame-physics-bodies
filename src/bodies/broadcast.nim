## The replay broadcast state channel.
##
## Derives the designed broadcast client's JSON chrome state from the live sim.
## The binary sprite stream stays the board renderer; this module produces the
## parallel chrome frame the client reads to draw the scorebug, match feed,
## banners, roster, transport and endcard.
##
## Beat-event derivation runs ONE SIM STEP AT A TIME (`stepEvents`) and is
## accumulated by the caller across a playback frame, so attribution stays
## exact even at 16x — never collapsing a whole span into one ambiguous marker.
## Every event here is a STATE DELTA, so it costs no replay bytes and reads
## identically live and in replay.
##
## Keys above the fold are ctf's and are consumed by the BYTE-IDENTICAL
## `chrome_common.js`; everything physics-bodies-specific is under `pb` and
## `intents` and is consumed only by the appended game block.

import std/[json, strutils]
import sim, global, labels, intents

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    prevRoundIndex: int32
    knockdowns: array[BodyCount, int32]
    contacts: array[BodyCount, int32]
    tilt: array[BodyCount, int32]
    grounded: array[BodyCount, int32]
    roundsWon: array[BodyCount, int32]
    roundLogLen: int
    matchPointSeen: array[BodyCount, bool]
    prevTurn: int

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby
  result.prevTurn = -1

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  for i in 0 ..< BodyCount:
    tracker.knockdowns[i] = sim.bodies[i].knockdowns
    tracker.contacts[i] = sim.bodies[i].contacts
    tracker.tilt[i] = sim.bodies[i].tipMilli
    tracker.grounded[i] = sim.bodies[i].groundedCount
    tracker.roundsWon[i] = sim.roundsWon[i]
  tracker.roundLogLen = sim.roundLog.len
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.prevRoundIndex = sim.roundIndex
  tracker.prevTurn = sim.turnIndexAt(sim.tickCount)
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots WITHOUT emitting events, after a seek / loop / skip. The next
  ## `stepEvents` then diffs against this frame, so no phantom beats fire.
  tracker.snapshot(sim)
  for i in 0 ..< BodyCount:
    tracker.matchPointSeen[i] =
      int(sim.roundsWon[i]) >= sim.config.roundsToClinch - 1

proc stepEvents*(sim: SimServer, tracker: var BroadcastTracker,
                 events: JsonNode) =
  ## Appends the beat events produced by the transition from the tracker's last
  ## snapshot to the current sim tick, then advances the tracker.
  if not tracker.initialized:
    tracker.resync(sim)
    return

  let tick = sim.tickCount

  if sim.phase != tracker.prevPhase:
    events.add(%*{"t": tick, "k": "phase",
      "phase": ($sim.phase).toLowerAscii})
    if sim.phase == GameOver:
      events.add(%*{
        "t": tick, "k": "gameover",
        "winner": (if sim.isDraw: "" else: sideText(int(sim.winner))),
        "draw": sim.isDraw,
        "tl": sim.timeLimitReached,
        "endRule": sim.endRule,
        "reason": sim.endReason
      })

  if sim.phase == Playing and
      (sim.roundIndex != tracker.prevRoundIndex or
       tracker.prevPhase == RoundReset or tracker.prevPhase == Lobby):
    events.add(%*{
      "t": tick, "k": "round_start", "round": int(sim.roundIndex) + 1,
      "of": sim.config.maxRounds,
      "radius": metres(sim.ringRadiusNow)
    })

  for i in 0 ..< BodyCount:
    let body = sim.bodies[i]
    if body.knockdowns > tracker.knockdowns[i]:
      events.add(%*{
        "t": tick, "k": "knockdown", "body": i, "team": sideText(i),
        "alias": alias(i), "count": int(body.knockdowns),
        "of": sim.config.knockdownsToLose
      })
    if body.tipMilli >= 500 and tracker.tilt[i] < 500:
      events.add(%*{
        "t": tick, "k": "stagger", "body": i, "team": sideText(i),
        "alias": alias(i), "tilt": tiltPct(body)
      })
    if body.groundedCount < int32(LegCount) and
        tracker.grounded[i] >= int32(LegCount) and body.downTicks == 0:
      events.add(%*{
        "t": tick, "k": "rim_slip", "body": i, "team": sideText(i),
        "alias": alias(i), "grounded": int(body.groundedCount)
      })
    if body.contacts > tracker.contacts[i]:
      events.add(%*{
        "t": tick, "k": "contact", "by": 1 - i, "body": i,
        "team": sideText(i), "alias": alias(i),
        "impulse": metres(sim.lastFx.impulseUm),
        "normal_deg": bearingDegFor(sim.lastFx.normalIdx)
      })
      if sim.lastFx.impulseUm > 0 and int(sim.lastFx.tick) == tick:
        events.add(%*{
          "t": tick, "k": "shove", "by": 1 - i, "team": sideText(1 - i),
          "impulse": metres(sim.lastFx.impulseUm)
        })

  if sim.roundLog.len > tracker.roundLogLen:
    for index in tracker.roundLogLen ..< sim.roundLog.len:
      let entry = sim.roundLog[index]
      if entry.reason == roundRingOut and entry.winner >= 0:
        events.add(%*{
          "t": tick, "k": "ring_out", "body": int(1 - entry.winner),
          "team": sideText(int(1 - entry.winner)),
          "winner": int(entry.winner),
          "radius": metres(sim.ringRadiusNow)
        })
      events.add(%*{
        "t": tick, "k": "round_end", "round": int(entry.round),
        "winner": int(entry.winner),
        "team": (if entry.winner < 0: "" else: sideText(int(entry.winner))),
        "reason": $entry.reason, "ticks": int(entry.ticks)
      })

  for i in 0 ..< BodyCount:
    if not tracker.matchPointSeen[i] and
        int(sim.roundsWon[i]) >= sim.config.roundsToClinch - 1 and
        int(sim.roundsWon[i]) < sim.config.roundsToClinch:
      tracker.matchPointSeen[i] = true
      events.add(%*{
        "t": tick, "k": "match_point", "body": i, "team": sideText(i),
        "alias": alias(i)
      })

  let turn = sim.turnIndexAt(tick)
  if turn != tracker.prevTurn and sim.phase == Playing:
    events.add(%*{"t": tick, "k": "turn_end", "turn": turn,
      "orders": sim.seatCount()})

  tracker.snapshot(sim)

# ---------------------------------------------------------------------------
#  The chrome frame
# ---------------------------------------------------------------------------

proc teamStateJson(sim: SimServer, bodyIndex: int): JsonNode =
  ## One bug's scorebug state. `lives` carries the ROUND WINS so
  ## chrome_common's team meter and momentum fallback read a meaningful number
  ## on a frame that predates the full lead series.
  let body = sim.bodies[bodyIndex]
  var policies = newJArray()
  let seat = sim.seatOfBody(bodyIndex)
  if seat >= 0 and sim.seatNames[seat].len > 0:
    policies.add %policyName(sim.seatNames[seat])
  %*{
    "lives": int(sim.roundsWon[bodyIndex]),
    "policies": policies,
    "score": round3(float(sim.matchScoreMicro(bodyIndex)) / 1_000_000.0),
    "rounds": int(sim.roundsWon[bodyIndex]),
    "knockdowns": int(sim.knockdownsSuffered[bodyIndex]),
    "ringOuts": int(sim.ringOuts[bodyIndex]),
    "knockouts": int(sim.knockouts[bodyIndex]),
    "contacts": int(body.contacts),
    "distFromCentre": metres(body.distFromCentre()),
    "tilt": tiltPct(body),
    "down": body.downTicks > 0,
    "grounded": int(body.groundedCount),
    "posture": $postureOf(body.posture())
  }

proc rosterJson(sim: SimServer): JsonNode =
  ## Spectator side ONLY: this is where the REAL policy names live.
  result = newJArray()
  for seat in 0 ..< BodyCount:
    let body = int(sim.perm[seat])
    let name =
      if sim.seatNames[seat].len > 0: sim.seatNames[seat]
      else: "seat " & $seat
    result.add %*{
      "s": seat,
      "name": name,
      "pol": policyName(name),
      "team": sideText(body),
      "alias": alias(body),
      "body": body,
      "alive": true,
      "lives": int(sim.roundsWon[body]),
      "kind": (if sim.seatPolicyKind[seat].len > 0: sim.seatPolicyKind[seat]
               else: "scripted"),
      "rounds": int(sim.roundsWon[body]),
      "knockdowns": int(sim.knockdownsSuffered[body]),
      "contacts": int(sim.bodies[body].contacts),
      "effortPct": sim.meanEffortPct(body),
      "llmTurns": int(sim.llmTurns[seat]),
      "fallbackTurns": int(sim.fallbackTurns[seat])
    }

proc bugJson(sim: SimServer, bodyIndex: int): JsonNode =
  let body = sim.bodies[bodyIndex]
  var feet = newJArray()
  for k in 0 ..< LegCount:
    feet.add %*{
      "p": [round2(viewX(body.footX[k])), round2(viewY(body.footY[k]))],
      "g": body.footGrounded[k],
      "load": (if body.footGrounded[k]: int(body.effort()) else: 0)
    }
  %*{
    "i": bodyIndex,
    "p": [round2(viewX(body.px)), round2(viewY(body.py))],
    "v": [velMs(body.vx), velMs(-body.vy)],
    "heading": headingDeg(body),
    "spin": spinDps(body),
    "posture": $postureOf(body.posture()),
    "effort": int(body.effort()),
    "drive": int(body.drive()),
    "tilt": tiltPct(body),
    "down": int(body.downTicks),
    "grounded": int(body.groundedCount),
    "feet": feet,
    "alias": alias(bodyIndex)
  }

proc pbJson(sim: SimServer): JsonNode =
  var bugs = newJArray()
  for i in 0 ..< BodyCount:
    bugs.add sim.bugJson(i)
  var log = newJArray()
  for entry in sim.roundLog:
    log.add %*{
      "round": int(entry.round), "winner": int(entry.winner),
      "reason": $entry.reason, "ticks": int(entry.ticks)
    }
  let fxAge = sim.tickCount - int(sim.lastFx.tick)
  %*{
    "ring": {
      "centre": [round2(viewX(RingCentreX)), round2(viewY(RingCentreY))],
      "r": metres(sim.ringRadiusNow),
      "r0": metres(int32(sim.config.ringRadiusUm)),
      "rmin": metres(int32(sim.config.ringRadiusMinUm))
    },
    "round": {
      "index": int(sim.roundIndex) + 1, "of": sim.config.maxRounds,
      "tick": int(sim.roundTick), "of_ticks": sim.config.roundTicks,
      "toClinch": sim.config.roundsToClinch,
      "knockdownsToLose": sim.config.knockdownsToLose,
      "log": log
    },
    "bugs": bugs,
    "contact": {
      "on": sim.lastFx.impulseUm > 0 and fxAge >= 0 and fxAge < 8,
      "point": (
        if sim.lastFx.impulseUm > 0:
          %[round2(viewX(sim.lastFx.x)), round2(viewY(sim.lastFx.y))]
        else: newJNull()),
      "normal": (
        if sim.lastFx.impulseUm > 0: %bearingDegFor(sim.lastFx.normalIdx)
        else: newJNull()),
      "impulse": metres(sim.lastFx.impulseUm),
      "lift": sim.lastFx.lift
    },
    "score": {
      sideText(0): round3(float(sim.matchScoreMicro(0)) / 1_000_000.0),
      sideText(1): round3(float(sim.matchScoreMicro(1)) / 1_000_000.0)
    }
  }

proc intentsJson(sim: SimServer): JsonNode =
  ## The commander lines. This is where a spectator SEES the LLM playing: the
  ## `note` and `say` each seat issued, live and in replay from one source.
  result = newJArray()
  for record in sim.feedIntents:
    try:
      result.add parseJson(record)
    except CatchableError:
      discard

proc buildStateJson*(sim: SimServer, events: JsonNode, playing: bool,
                     speed, maxTick: int, looping, transportEnabled: bool,
                     mismatchTick: int, leadSeries: seq[seq[int]] = @[],
                     startTick = 0, endHoldSeconds = 0, skipLulls = false,
                     fastForwarding = false,
                     lullSpans: seq[array[2, int]] = @[],
                     beatEvents: JsonNode = nil): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE (scores, round
  ## tallies, roster, verdict) is always present, so even a frame reached by a
  ## seek hydrates the scorebug and endcard with no events.
  var teams = newJObject()
  for i in 0 ..< BodyCount:
    teams[sideText(i)] = sim.teamStateJson(i)

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    # BOARD pixels per LOGICAL map pixel: everything the viewer positions
    # with lives in board pixels, so a control that must move a fixed WORLD
    # distance can only do it by multiplying through this.
    "bs": boardRenderScaleFor(MapWidth, MapHeight),
    "pov": -1,
    "teams": teams,
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events),
    "turn": sim.turnIndexAt(sim.tickCount),
    "turns": sim.turnsPerEpisode(),
    "turnTicks": sim.config.turnTicks,
    "pb": sim.pbJson(),
    "intents": sim.intentsJson()
  }

  if leadSeries.len > 0:
    var teamNames = newJArray()
    for i in 0 ..< BodyCount:
      teamNames.add %sideText(i)
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add %value
      pts.add row
    state["lead"] = %*{"teams": teamNames, "pts": pts}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add %*[span[0], span[1]]
    state["lulls"] = spans

  ## The endcard is STATE, not an event: present on every game-over frame so a
  ## viewer who seeks straight to the end still sees the verdict. `draw` is
  ## read before `winner` by every consumer.
  if sim.phase == GameOver:
    var overTeams = newJObject()
    for i in 0 ..< BodyCount:
      overTeams[sideText(i)] = %*{
        "rounds": int(sim.roundsWon[i]),
        "ringOuts": int(sim.ringOuts[i]),
        "knockouts": int(sim.knockouts[i]),
        "knockdowns": int(sim.knockdownsSuffered[i]),
        "contacts": int(sim.bodies[i].contacts),
        "effortPct": sim.meanEffortPct(i),
        "lives": int(sim.roundsWon[i])
      }
    let winnerBody = int(sim.winner)
    state["over"] = %*{
      "winner": (if sim.isDraw: "" else: sideText(winnerBody)),
      "draw": sim.isDraw,
      "timeLimit": sim.timeLimitReached,
      "endRule": sim.endRule,
      "reason": sim.endReason,
      "score": round3(
        float(sim.matchScoreMicro(max(0, winnerBody))) / 1_000_000.0),
      "ticks": sim.tickCount,
      "teams": overTeams
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state
