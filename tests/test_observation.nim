## 8. THE OBSERVATION CONTRACT — the two name spaces, and what a seat may not
## see.

import std/[json, random, strformat, strutils]
import bitworld/spriteprotocol
import bodies/[sim, global, broadcast, intents, control, baselines, llm]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

const
  SecretNames = ["daveey", "daveey-1", "physics-bodies-ringcraft",
                 "physics-bodies-toppler"]
  SecretPrompt = "MY SECRET STRATEGY: always circle left before committing"
  SecretNote = "the other seat is thinking about a lift, apparently"
  SecretSay = "psst, this is the other seat's line"

var rng = initRand(0x0B5E)

# --- what the composed USER MESSAGE contains, and what it must not ------
block:
  for _ in 0 ..< 200:
    var cfg = defaultMatchConfig(rng.rand(1 .. 1_000_000))
    var sim = initSimServer(cfg)
    sim.gameEventLoggingEnabled = false
    sim.phase = Playing
    sim.ringRadiusNow = int32(rng.rand(int(RingRadiusMin) .. int(RingRadius0)))
    for i in 0 ..< BodyCount:
      sim.bodies[i] = randomBody(rng, sim.ringRadiusNow)
    for seat in 0 ..< BodyCount:
      discard sim.addPlayer(SecretNames[seat], seat, "tok-" & $seat)
      sim.seatNames[seat] = SecretNames[seat]
      sim.seatPolicyKind[seat] = "llm"
    sim.roundIndex = int32(rng.rand(0 ..< MaxRoundsDefault))
    ## The OTHER seat's mind, planted where a leak would show up.
    var otherIntent = defaultIntent()
    otherIntent.note = SecretNote
    otherIntent.say = sanitizeSay(SecretSay)
    otherIntent.stance = stanceLift
    otherIntent.aggression = 9
    sim.pushFeedIntent(boundedIntentRecord(otherIntent, 3, 1, 1))

    for seat in 0 ..< BodyCount:
      let
        view = seatView(sim, seat, false, defaultIntent())
        message = userMessage(SecretPrompt, seatViewJson(view))
        body = sim.bodyOfSeat(seat)
        foe = 1 - body

      ## It DOES carry the full physical state of BOTH bodies and the ring.
      let node = parseJson(seatViewJson(view))
      for side in ["you", "foe"]:
        for key in ["pos", "vel", "speed_m_s", "heading_deg", "spin_dps",
                    "posture", "effort", "reach_m", "tilt_pct",
                    "grounded_legs", "down_ticks", "dist_from_centre_m",
                    "dist_to_rim_m"]:
          check node[side].hasKey(key),
            &"the observation is missing {side}.{key}"
      check node["you"].hasKey("feet") and node["you"]["feet"].len == LegCount,
        "the observation does not carry all four of your feet"
      for key in ["centre", "radius_m", "min_radius_m", "shrink_starts_in_s",
                  "radius_at_round_end_m"]:
        check node["ring"].hasKey(key), &"the observation is missing ring.{key}"
      check node["you"]["alias"].getStr() == alias(body),
        "the observation names your bug wrongly"
      check node["foe"]["alias"].getStr() == alias(foe),
        "the observation names the other bug wrongly"

      ## It does NOT carry the other seat's MIND.
      check not message.contains(SecretNote),
        "the observation leaked the other seat's `note`"
      check not message.contains(SecretSay),
        "the observation leaked the other seat's `say`"
      check not message.contains("policyKind") and
        not message.contains("fallback"),
        "the observation leaked the other seat's policy kind / fallback state"
      check not message.contains("latency"),
        "the observation leaked call latency"

      ## …nor ANY real player name, `perm`, the seed, the RNG state, the future
      ## start axes, the variant name or a socket address.
      for name in SecretNames:
        if name == SecretNames[seat]:
          continue
        check not seatViewJson(view).contains(name),
          &"the observation leaked the real policy name {name}"
      check not seatViewJson(view).contains("perm"),
        "the observation leaked `perm`"
      check not seatViewJson(view).contains("seed"),
        "the observation leaked the seed"
      check not seatViewJson(view).contains("rngState") and
        not seatViewJson(view).contains("startAxis"),
        "the observation leaked the RNG state or the future start axes"
      check not seatViewJson(view).contains("variant"),
        "the observation leaked the variant name"

      ## The seat's OWN prompt rides in the operator block, which is the one
      ## place it is allowed — and it is never in the view JSON itself.
      check message.contains(SecretPrompt),
        "the operator block did not carry the seat's own prompt"
      check not seatViewJson(view).contains(SecretPrompt),
        "the seat's prompt leaked into the observation JSON"

# --- THE TWO NAME SPACES ------------------------------------------------
block:
  var cfg = defaultMatchConfig()
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  for seat in 0 ..< BodyCount:
    discard sim.addPlayer(SecretNames[seat], seat, "")
    sim.seatNames[seat] = SecretNames[seat]
    sim.seatPolicyKind[seat] = "llm"

  ## In-game: BUG-1 / BUG-2 and nothing else. The PLAYER stream's board labels
  ## are the sprite labels, so they are read straight off the emitted packet.
  var state = initPlayerViewerState()
  var next: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(0, state, next)
  var labels = ""
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite:
      labels.add message.sprite.label
      labels.add "\n"
  check labels.len > 0, "the player stream emitted no labelled sprites"
  for name in SecretNames:
    check not labels.contains(name),
      &"a player-stream board label carried the real policy name {name}"
  check labels.contains("BUG-1") and labels.contains("BUG-2"),
    "the player stream's board labels do not carry the anonymous aliases"

  ## Spectator side: the chrome roster, the endcard and results.names DO carry
  ## the real names.
  let chrome = sim.chromeFrame()
  var rosterNames: seq[string]
  for entry in chrome["roster"]:
    rosterNames.add entry["name"].getStr()
  for seat in 0 ..< BodyCount:
    check SecretNames[seat] in rosterNames,
      &"the chrome roster is missing the real policy name {SecretNames[seat]}"
  let results = parseJson(sim.playerResultsJson())
  for seat in 0 ..< BodyCount:
    check results["names"][seat].getStr() == SecretNames[seat],
      "results.names does not carry the real policy names in seat order"
    check results["aliases"][seat].getStr() ==
      alias(int(sim.perm[seat])),
      "results.aliases does not carry the in-game aliases"

# --- driveCommand's inputs are structurally limited --------------------
block:
  ## The controller may see the sim state, the body index, ITS SEAT's intent and
  ## the tick — and nothing else. The signature is the enforcement.
  let source = readFile(repoFile("src/bodies/control.nim"))
  check source.contains(
    "proc driveCommand*(ctl: var ControlState, sim: SimServer, bodyIndex: int,"),
    "driveCommand's signature changed — re-check what it can now see"
  check source.contains("intent: BugIntent, tick: int): uint8"),
    "driveCommand no longer takes exactly (intent, tick)"
  ## And it cannot REACH the other seat's mind: no line of code (comments
  ## stripped — the module documents the ban) names the decision engine, the
  ## seat policies, the feed, the roster names or a prompt.
  var code = ""
  for rawLine in source.splitLines():
    var line = rawLine
    let doc = line.find("##")
    if doc >= 0:
      line = line[0 ..< doc]
    let hash = line.find('#')
    if hash >= 0:
      line = line[0 ..< hash]
    code.add line
    code.add "\n"
  for forbidden in ["DecisionEngine", "SeatPolicy", "feedIntents",
                    "seatNames", "prompt", "seatPolicyKind"]:
    check not code.contains(forbidden),
      &"control.nim references `{forbidden}` — the controller must not see it"

if failures > 0:
  quit("test_observation: " & $failures & " failure(s)", 1)
echo "test_observation: ok"
