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
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to the
## scripted layer INSTANTLY, with no network wait — which is what lets offline
## certification finish in seconds.

import std/[json, os, strutils]
import bitworld/runtime
import curly
import sim_types, intents

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
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

proc requestFor*(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
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

const SystemPrompt* = """
You are ONE of TWO four-legged robot bugs in a round sumo ring, seen from
above. Coordinates are metres from the arena's bottom-left corner; x runs
right, y runs up. Bearings are degrees counter-clockwise from east: 0 = right,
90 = up, 180 = left, 270 = down. The ring is a circle centred on (4.80, 3.20).
It starts 3.00 m in radius and SHRINKS from 6 seconds into every round, down to
1.80 m. There is nothing outside it.
HOW YOU WIN A ROUND: the other bug's body centre crosses the rim (a RING OUT),
or you knock it down THREE times. If the round clock runs out, the bug with
fewer knockdowns wins, and if that is level, the bug CLOSER TO THE CENTRE wins.
Best of five rounds wins the match. Every round you win is +1 to you and -1 to
the other bug: this is strictly zero sum.
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
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
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
