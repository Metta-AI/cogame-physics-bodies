## Claude-backed bug orders. A policy is just a prompt: the GAME SERVER
## composes the seat's observation plus that seat's PLAYER_PROMPT and asks
## Claude what the bug does for the next 1.5 seconds.
##
## Kept from `coworld-ctf`'s `src/ctf/llm.nim` behaviour for behaviour — the
## credential ladder, the single-haiku model list, the `throttled` fast-fail,
## the fence-tolerant JSON extraction and the rune-boundary truncation are all
## that file's, because they are all scar tissue from real hosted failures.
##
## THE RING is a SIMULTANEOUS-decision game, so both seats' calls go out as ONE
## parallel batch per turn (`curly.makeRequests`, see decide.nim). Seats are
## never queried sequentially: that is the documented way to blow the
## wall-clock budget.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT (hosted), or local Bedrock bearer token
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to the
## scripted layer INSTANTLY, with no network wait — which is what lets offline
## certification finish in seconds.

import std/[json, os, strutils]
import bitworld/runtime
import curly
import sim_types, intents, prompts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside the
      ## same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a refused call.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "physics-bodies llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. There is exactly ONE candidate — haiku — because every sonnet
  ## inference profile times out on every sidecar call (cogame-raid round 2,
  ## 2026-08-23). With no second candidate a throttle fails fast (see
  ## `LlmClient.throttled`) and the seat plays the scripted fallback for that
  ## turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "physics-bodies llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "physics-bodies llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "physics-bodies llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "physics-bodies llm: no credentials — the LLM provider is ",
      "unavailable; every turn is falling back to the scripted layer"

proc requestFor*(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(client: LlmClient, response: Response, error, url: string): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const CanonicalIntroduction = "You are ONE of TWO four-legged robot bugs in a round sumo ring, seen from\nabove. "

const Rules = """Coordinates are metres from the arena's bottom-left corner; x runs
right, y runs up. Bearings are degrees counter-clockwise from east: 0 = right,
90 = up, 180 = left, 270 = down. The ring is a circle centred on (4.80, 3.20).
It starts 3.00 m in radius and SHRINKS from 6 seconds into every round, down to
1.80 m. There is nothing outside it.
HOW YOU WIN A ROUND: the other bug's body centre crosses the rim (a RING OUT),
or you knock it down THREE times. If the round clock runs out, the bug with
fewer knockdowns wins, and if that is level, the bug CLOSER TO THE CENTRE wins.
The observation gives the round limit and wins required to clinch the match.
A round win earns 1 point, with an extra 0.25 for a ring out or three-knockdown
win; a decision win has no bonus. Draws earn neither side points. Your score is
your earned points minus the opponent's: this is strictly zero sum.
HOW A BUG MOVES: you push with the leg that has floor under it. A leg whose
foot is over the rim finds NO FLOOR - standing near the edge costs you push and
costs you balance. Posture matters: LOW is wide, slow, hard to move and hard to
tip; HIGH is tall and fast but tips easily; LIFT gets under the other bug and
levers it over, at some risk to yourself.
TILT: off-centre hits, your own spin, standing tall and being levered all fill
your tilt gauge. Full tilt and you FALL DOWN for 1.5 seconds - you cannot push
and you can be shoved straight out while you lie there.
Every 1.5 seconds you set your ORDER for the next 1.5 seconds. A deterministic
autopilot runs it 24 times a second: it steers, it leads a moving target, it
keeps you off the rim unless you tell it not to. You choose WHAT to do and HOW
hard. You CANNOT talk to the other bug and it never sees anything you write.
"""

const ReplyRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars, your reasoning",
 "stance":"charge"|"brace"|"circle"|"lift"|"retreat"|"centre",
   // charge  : drive into the other bug where it WILL be in lead_ticks, and
   //           shove. The bread and butter.
   // brace   : plant LOW facing the other bug and absorb. You barely move,
   //           you take less tilt, and a bug that charges a brace bounces.
   // circle  : orbit the other bug at about 1.40 m in circle_dir, trying to
   //           end up with the rim behind IT and the centre behind YOU.
   // lift    : close and get under it - the knockdown attempt. Slow, and it
   //           loads tilt onto you too.
   // retreat : back toward the ring centre away from the other bug.
   // centre  : walk to the ring centre and hold it. Wins a decision.
 "aim":"foe"|"centre"|"bearing",   // what "charge"/"circle" point at
 "bearing_deg":0..359,             // only read when aim is "bearing"
 "aggression":0..10,               // 0 = coast, 10 = all in. At 10 the
                                   // autopilot's rim guard is HALVED: you may
                                   // push yourself out. That is the trade.
 "posture_bias":"low"|"even"|"high"|"auto",
 "lead_ticks":0..24,               // aim where it will be this many ticks from
                                   // now (24 ticks = 1 second)
 "circle_dir":-1 or 1,             // -1 = clockwise, 1 = counter-clockwise
 "say":"<=48 chars"}               // spectators only; the other bug never sees it
"""

proc systemPrompt*(selection: PromptSelection): string =
  if selection.selectedVariant == pvCanonical:
    return CanonicalIntroduction & Rules & ReplyRules
  let arena = "You control one of two four-legged robot bugs, viewed from above in a circular sumo ring. " &
    "Coordinates are metres from the arena's bottom-left: x points right and y points up. " &
    "Bearings turn counter-clockwise from east: 0 right, 90 up, 180 left, 270 down. " &
    "The ring centre is (4.80, 3.20). Its radius starts at 3.00 metres, begins shrinking " &
    "six seconds into each round, and reaches 1.80 metres. There is no floor outside."
  let winning = "Win a round by forcing the other bug's torso centre across the rim or knocking " &
    "it down three times. At the round deadline, fewer knockdowns wins; a tie goes to the " &
    "bug nearer the centre. The observation states the round limit and wins needed to clinch. " &
    "Each round win earns one point, plus 0.25 for a ring out or three-knockdown win; " &
    "a decision win has no bonus. Draws award neither side points. Your score is your " &
    "earned points minus the opponent's, so scoring is strictly zero-sum."
  let support = "A bug pushes through legs supported by the floor. A foot beyond the rim provides " &
    "no support, so the edge reduces both pushing force and balance. LOW posture is wide, " &
    "slow, resistant to movement and hard to tip. HIGH is tall and fast but easier to tip. " &
    "LIFT gets underneath the opponent to lever it over, risking your own balance."
  let tilt = "Off-centre impacts, your own spin, tall posture, and an opponent levering underneath " &
    "you increase tilt. A full tilt gauge knocks you down for 1.5 seconds. While down, " &
    "you cannot push and the opponent can shove you out."
  let orders = "Choose an order every 1.5 seconds for the next 1.5 seconds. The deterministic " &
    "autopilot executes it 24 times per second, handling steering, moving-target lead, " &
    "and rim avoidance unless instructed otherwise. You choose the action and its intensity. " &
    "You cannot communicate with the other bug; none of your written text is visible to it."
  let briefing = case selection.selectedVariant
    of pvPlain: arena & "\n\n" & winning & "\n\n" & support & "\n\n" & tilt & "\n\n" & orders
    of pvNumbered: """1. Arena. You operate one of two four-legged robotic bugs in a circular sumo arena, seen from above. Metres are measured from the bottom-left, with x rightward and y upward. Angles increase counter-clockwise from east: right 0, up 90, left 180, down 270. The centre is (4.80, 3.20). Radius begins at 3.00 m, starts contracting six seconds into a round, and shrinks to 1.80 m. There is no floor beyond the circle.
2. Victory. Force the opponent's torso centre over the edge or knock it down three times to win the round. At timeout, fewer knockdowns wins, then proximity to the centre breaks a tie. Consult the observation for the round limit and wins needed to clinch. A round win earns 1 point; ring outs and three-knockdown wins add 0.25, while decision wins add nothing extra. Draws award no points. Subtract the opponent's earned points from yours to get your zero-sum score.
3. Support. Only legs with floor beneath them can push. Feet beyond the rim cannot support you, weakening force and balance. LOW is wide and slow, resists displacement, and is difficult to tip. HIGH is taller and faster but less stable. LIFT levers under the other bug and also risks your balance.
4. Falling. Off-centre collisions, spinning, tall posture, and an opponent levering underneath increase tilt. At full tilt you fall for 1.5 seconds, cannot push, and can be shoved out.
5. Orders. Once every 1.5 seconds select the next 1.5 seconds of action and intensity. A deterministic autopilot runs at 24 updates per second, steering, leading moving targets, and guarding the rim unless told otherwise. The other bug never sees your written text; there is no communication channel."""
    of pvQuestions: """What do I control? One four-legged robot bug facing another in an overhead circular sumo ring. Positions use metres from the bottom-left corner: x increases right and y increases up. Bearings run counter-clockwise from east, making 0 right, 90 up, 180 left, and 270 down. The circle is centred at (4.80, 3.20). Its initial 3.00 m radius begins shrinking six seconds after each round starts, down to 1.80 m. Outside is unsupported space.
How do I win? Send the opposing torso centre beyond the rim, or cause its third knockdown. If time expires first, the bug with fewer knockdowns wins; equal counts favour the bug nearer the centre. The observation supplies the match's round cap and clinching win count. Winning a round yields 1 point, plus 0.25 when won by ring out or three knockdowns. A decision earns no extra bonus and a draw pays neither bug. Final score subtracts their points from yours, giving opposite scores.
What provides leverage? Floor beneath your legs. A foot over the edge contributes no support, reducing both balance and pushing power. LOW makes you wide, slow, hard to displace and hard to topple. HIGH trades stability for height and speed. LIFT gets below the foe to lever it over at some risk to yourself.
What fills tilt? Hits away from your centre, your own spin, height, and being levered from below. Filling the gauge knocks you down for 1.5 seconds. You lose pushing ability while prone and may be shoved outside.
How do I act? Set an order and intensity every 1.5 seconds for the following 1.5 seconds. The deterministic autopilot executes at 24 Hz, handling steering, target lead and rim avoidance unless overridden. None of your writing reaches the other bug."""
    of pvReordered: """OBJECTIVE
A round ends in your favour when the foe's torso centre leaves the ring or it suffers three knockdowns. A time-limit decision favours fewer knockdowns, then the bug closer to the centre. Use the observation's round limit and required wins for the match. Each round win contributes 1 point, with 0.25 more for a ring out or a three-knockdown victory. Decision victories have no extra award; draws pay neither side. Your total minus the opponent's total is your score, so the match is zero-sum.
CONTROL
Choose what to do and how intensely once per 1.5 seconds, covering the next 1.5 seconds. A deterministic controller executes 24 times each second, steering, anticipating a moving target and avoiding the edge unless instructed otherwise. Written text is not visible to the other bug, and you cannot converse with it.
BALANCE
An off-centre blow, spinning, a tall posture or being levered from underneath adds tilt. Filling the tilt gauge leaves you down for 1.5 seconds: unable to push and vulnerable to being shoved out. Floor contact through the legs supplies pushing support. A foot outside the rim finds none, so the edge costs power and balance. LOW is broad, slow and resistant to displacement and tipping; HIGH is tall and quick but tips more easily. LIFT tries to get underneath and lever the foe over, risking your stability too.
GEOMETRY
You are one of two four-legged robot bugs, viewed from above. Coordinates in metres start at the bottom-left, with rightward x and upward y. Bearings turn counter-clockwise from east: 0 right, 90 up, 180 left, 270 down. The circular arena has centre (4.80, 3.20) and starts with radius 3.00 m. Six seconds into each round it begins shrinking toward 1.80 m. Beyond the rim there is no floor."""
    of pvHeldoutBriefing: """Guide your four-legged robot against the other bug in this overhead sumo arena. Read positions in metres from the bottom-left; right is increasing x and up is increasing y. Angles are counter-clockwise from east: east/right 0, up 90, left 180, down 270. The ring surrounds (4.80, 3.20), initially extending 3.00 m from that centre. Contraction starts six seconds into each round and continues down to 1.80 m. Nothing supports a foot beyond the edge.

Secure floor support before relying on a shove. Your legs can push only when their feet have floor beneath them. Near the boundary you lose both pushing strength and balance. A LOW bug spreads wide, moves slowly and is hard to shift or topple. HIGH is taller and quicker but more vulnerable to tipping. LIFT attempts to get under the opponent and lever it over, endangering your own stability as well.

Monitor tilt: blows off the centre line, your own rotation, tall posture and leverage from underneath all increase it. A full gauge means 1.5 seconds on the ground. You cannot push during that interval, and the opponent may shove you over the edge.

Win by forcing the opposing torso centre outside or by knocking that bug down three times. At the round deadline, fewer knockdowns decides the winner; if equal, being closer to the centre wins. Match length and wins needed to clinch are stated in the observation. Bank 1 point per round win, adding 0.25 for a ring out or three-knockdown win. A decision win adds no bonus, and draws bank nothing for either side. Your score is what you bank minus what the opponent banks.

Issue an action and intensity for each 1.5-second interval. The deterministic autopilot runs your order 24 times per second, taking care of steering, moving-target lead and rim protection unless you direct otherwise. All written text stays unseen by the opposing bug; it is not a means of communication."""
    of pvHeldoutReference: """Arena reference: two four-legged robots contest a circular sumo ring under an overhead view. Position units are metres, with origin at the bottom-left, positive x to the right and positive y upward. Bearings increase counter-clockwise from east (0 right; 90 up; 180 left; 270 down). Ring centre: (4.80, 3.20). Initial radius: 3.00 m. Shrinking begins six seconds into every round and reaches 1.80 m. No floor exists outside the rim.
Support and posture reference: force comes from legs supported by floor. Unsupported feet beyond the boundary reduce available push and balance. LOW is wide, slow, hard to move and hard to overturn. HIGH is tall and fast with greater tipping risk. LIFT seeks leverage beneath the opponent but also puts the lifting bug's balance at risk.
Instability reference: off-centre impacts, self-generated spin, tall posture and an opponent levering underneath fill the tilt gauge. At capacity, the bug falls for 1.5 seconds. A fallen bug cannot push and remains susceptible to being shoved out.
Outcome reference: crossing the rim with the torso centre loses a round, as does a third knockdown. Expiry of round time compares knockdown counts first (fewer wins), then distance to centre (nearer wins). The observation specifies the round limit and clinching requirement. A win yields 1 point and a ring-out or three-knockdown win yields an additional 0.25. Decision wins have no bonus. Draws yield no points. Scoring is the difference between the two bugs' earned totals and is strictly zero-sum.
Order reference: choose an action and strength every 1.5 seconds for the next 1.5 seconds. Deterministic execution occurs at 24 Hz, including steering, target-motion lead and rim avoidance unless ordered otherwise. The opponent receives none of your written text; communication with it is unavailable."""
    of pvCanonical, pvMixed: raise newException(ValueError, "alternate wording must resolve")
  briefing & "\n\n" & ReplyRules

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## observation (built server-side — see baselines.seatViewJson).
  operatorBlock(operatorPrompt) & viewJson

proc requestedModel*(client: LlmClient): string =
  if client.transport == ltBedrock: client.bedrockModels[client.bedrockModel]
  else: client.model
