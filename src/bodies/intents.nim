## The order schema: what a policy (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and how an illegal reply is REPAIRED rather than
## rejected.
##
## Both policy kinds emit the SAME object, so one validator covers both — that
## is what makes the bounded-orders test in tests/test_baselines.nim meaningful
## and a scripted baseline legal by construction.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary (`runeLen` / `runeSubStr`).
## Slicing a string by BYTE index anywhere on the path to the replay is
## forbidden: a byte-truncated multi-byte character renders fine in a browser
## and then fails a strict UTF-8 parser.

import std/[json, math, strutils, unicode]
import sim_types

type
  Stance* = enum
    ## A closed enum. An unrecognised stance is repaired to LAST TURN's, else
    ## `charge` — never dropped, so a bug is never left uncommanded.
    stanceCharge = "charge"
    stanceBrace = "brace"
    stanceCircle = "circle"
    stanceLift = "lift"
    stanceRetreat = "retreat"
    stanceCentre = "centre"

  Aim* = enum
    aimFoe = "foe"
    aimCentre = "centre"
    aimBearing = "bearing"

  PostureBias* = enum
    biasLow = "low"
    biasEven = "even"
    biasHigh = "high"
    biasAuto = "auto"

  IntentSource* = enum
    isLlm = "llm"
    isScripted = "scripted"
    isFallback = "fallback"

  BugIntent* = object
    ## One seat's tactical order for the next K = 36 ticks. The deterministic
    ## controller compiles it into a command byte 24 times a second.
    note*: string              ## <= MaxNoteRunes
    stance*: Stance
    aim*: Aim
    bearingDeg*: int           ## 0 .. 359, read only when aim is `bearing`
    aggression*: int           ## 0 .. 10
    postureBias*: PostureBias
    leadTicks*: int            ## 0 .. 24
    circleDir*: int            ## -1 or +1
    say*: string               ## <= MaxSayRunes, sanitized; spectators only
    source*: IntentSource
    latencyMs*: int

  IntentError* = object of ValueError

proc defaultIntent*(): BugIntent =
  ## The floor every repair path lands on.
  BugIntent(
    stance: stanceCharge, aim: aimFoe, bearingDeg: 0, aggression: 7,
    postureBias: biasAuto, leadTicks: 4, circleDir: 1, source: isScripted)

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single place
  ## any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A bug's spectator line: capped at MaxSayRunes on a rune boundary FIRST,
  ## then run through the printable-ASCII shout filter. That order matters —
  ## the rune cut never leaves half a codepoint for the ASCII filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    ## Braces are excluded deliberately: the replay chat stream tells a CONTROL
    ## record from a bug's line by a leading '{', and a line that could start
    ## with one would make that discrimination ambiguous.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The policy's own reasoning line, as it reaches the replay and the feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(IntentError,
      "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readNumber(node: JsonNode): tuple[ok: bool, value: float] =
  ## One numeric field: an int, a float, or a NUMERIC STRING. Anything
  ## non-finite reports `ok = false` so the caller applies its own repair
  ## rather than inventing a value.
  if node.isNil:
    return (false, 0.0)
  case node.kind
  of JInt:
    (true, float(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0.0) else: (true, f)
  of JString:
    try: (true, parseFloat(node.getStr().strip())) except CatchableError: (false, 0.0)
  of JBool:
    (true, (if node.getBool(): 1.0 else: 0.0))
  else:
    (false, 0.0)

proc normalizeKey(text: string): string =
  text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")

proc parseStance*(text: string, fallback: Stance): tuple[ok: bool, value: Stance] =
  ## Case-insensitive, whitespace-tolerant, and it accepts the two synonyms
  ## models actually emit: `push` for charge and `hold` for brace.
  let key = normalizeKey(text)
  if key.len == 0:
    return (false, fallback)
  if key == "push":
    return (true, stanceCharge)
  if key == "hold":
    return (true, stanceBrace)
  if key == "center":
    return (true, stanceCentre)
  for stance in Stance:
    if $stance == key:
      return (true, stance)
  (false, fallback)

proc parseAim*(text: string): Aim =
  let key = normalizeKey(text)
  if key == "center":
    return aimCentre
  for aim in Aim:
    if $aim == key:
      return aim
  aimFoe

proc parsePostureBias*(text: string): PostureBias =
  let key = normalizeKey(text)
  for bias in PostureBias:
    if $bias == key:
      return bias
  biasAuto

proc parseCircleDir*(node: JsonNode, fallback: int): int =
  ## Accepts a number, a sign, or the words models use.
  if node.isNil:
    return fallback
  if node.kind == JString:
    case normalizeKey(node.getStr())
    of "cw", "clockwise", "right": return -1
    of "ccw", "counterclockwise", "counter_clockwise", "left": return 1
    else: discard
  let num = readNumber(node)
  if not num.ok:
    return fallback
  if num.value < 0.0: -1 else: 1

proc parseIntentObject*(payload: JsonNode, previous: BugIntent,
                        hasPrevious: bool): BugIntent =
  ## Turns one parsed reply into a LEGAL intent, repairing every field the
  ## schema bounds rather than rejecting the reply. Raises `IntentError` only
  ## when no object with at least one usable field can be recovered — that is
  ## the single condition the retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(IntentError, "reply is not a JSON object")
  result = if hasPrevious: previous else: defaultIntent()
  result.source = isLlm
  result.latencyMs = 0
  result.note = ""
  result.say = ""
  var usable = 0

  if not payload{"note"}.isNil:
    result.note = sanitizeNote(payload{"note"}.getStr())
    if result.note.len > 0:
      inc usable

  let stance = parseStance(payload{"stance"}.getStr(), result.stance)
  if stance.ok:
    inc usable
  result.stance = stance.value

  if not payload{"aim"}.isNil:
    result.aim = parseAim(payload{"aim"}.getStr())
    inc usable

  let bearing = readNumber(payload{"bearing_deg"})
  if bearing.ok:
    inc usable
    var deg = bearing.value
    ## A bearing given in RADIANS is a real model habit: |v| <= 6.3 with a
    ## fractional part cannot be a useful degree value, so convert it.
    if abs(deg) <= 6.3 and deg != 0.0 and abs(deg - deg.round()) > 0.001:
      deg = deg * 180.0 / PI
    var whole = int(deg.round()) mod 360
    if whole < 0:
      whole += 360
    result.bearingDeg = whole

  let aggression = readNumber(payload{"aggression"})
  if aggression.ok:
    inc usable
    var value = aggression.value
    ## A percentage (0..100) is the other common shape.
    if value > 10.0:
      value = value / 10.0
    result.aggression = clamp(int(value.round()), 0, 10)

  if not payload{"posture_bias"}.isNil:
    result.postureBias = parsePostureBias(payload{"posture_bias"}.getStr())
    inc usable

  let lead = readNumber(payload{"lead_ticks"})
  if lead.ok:
    inc usable
    var ticks = lead.value
    ## Given in SECONDS: a decimal below 2 is a fraction of a second, not a
    ## tick count.
    if ticks > 0.0 and ticks < 2.0 and abs(ticks - ticks.round()) > 0.001:
      ticks = ticks * float(TargetFps)
    result.leadTicks = clamp(int(ticks.round()), 0, 24)

  if not payload{"circle_dir"}.isNil:
    result.circleDir = parseCircleDir(payload{"circle_dir"}, result.circleDir)
    inc usable

  if not payload{"say"}.isNil:
    result.say = sanitizeSay(payload{"say"}.getStr())

  if usable == 0:
    raise newException(IntentError, "reply carried no usable field")

  ## Belt and braces: every field is inside its documented range whatever the
  ## reply said, so the controller can never see an illegal intent.
  result.bearingDeg = ((result.bearingDeg mod 360) + 360) mod 360
  result.aggression = clamp(result.aggression, 0, 10)
  result.leadTicks = clamp(result.leadTicks, 0, 24)
  result.circleDir = if result.circleDir < 0: -1 else: 1
  result.note = result.note.truncateRunes(MaxNoteRunes)
  result.say = sanitizeSay(result.say)

proc parseIntentReply*(text: string, previous: BugIntent,
                       hasPrevious: bool): BugIntent =
  parseIntentObject(extractJsonObject(text), previous, hasPrevious)

proc intentJson*(intent: BugIntent, turn, seat, body: int): JsonNode =
  ## The replay chat record for one turn's intent. Re-applied at playback into
  ## NON-HASHED fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  %*{
    "k": "intent",
    "turn": turn,
    "seat": seat,
    "alias": alias(body),
    "body": body,
    "source": $intent.source,
    "latency_ms": intent.latencyMs,
    "note": intent.note,
    "stance": $intent.stance,
    "aim": $intent.aim,
    "bearing_deg": intent.bearingDeg,
    "aggression": intent.aggression,
    "posture_bias": $intent.postureBias,
    "lead_ticks": intent.leadTicks,
    "circle_dir": intent.circleDir,
    "say": intent.say
  }

proc boundedIntentRecord*(intent: BugIntent, turn, seat, body: int): string =
  ## The serialized intent record, guaranteed <= MaxIntentRunes. The note is
  ## the only unbounded-in-practice field, so it is the one that shrinks; the
  ## cut still lands on a rune boundary. NEVER cut the serialized string —
  ## that would emit broken JSON, which is the exact failure the rune rule
  ## exists to prevent.
  var trimmed = intent
  result = $trimmed.intentJson(turn, seat, body)
  var guard = 0
  while result.runeLen > MaxIntentRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $trimmed.intentJson(turn, seat, body)

proc registerRecord*(seat, body: int, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's PROMPT is never written:
  ## only the policy label, the kind, and which baseline a scripted seat chose.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias(body),
    "body": body,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc fallbackRecord*(turn, seat, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc roundRecord*(round, winner: int, reason: string, ticks: int,
                  knockdowns: array[BodyCount, int32]): string =
  ## LOAD-BEARING: `bankRound` applies this identically on record and on
  ## playback, so it is written for every completed round.
  $(%*{
    "k": "round",
    "round": round,
    "winner": winner,
    "reason": reason,
    "ticks": ticks,
    "knockdowns": [int(knockdowns[0]), int(knockdowns[1])]
  })

proc stopRecord*(tick: int, cause: string): string =
  ## LOAD-BEARING (the particle-worlds 13c66d7 fix).
  $(%*{"k": "stop", "tick": tick, "cause": cause})
