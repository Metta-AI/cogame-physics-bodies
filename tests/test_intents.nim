## 6. Tolerant parsing, repair, and the RUNE discipline.

import std/[json, strformat, strutils, unicode]
import bodies/[sim, intents]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

let base = defaultIntent()

proc parsed(text: string, previous = base, hasPrevious = true): BugIntent =
  parseIntentReply(text, previous, hasPrevious)

# --- prose-prefixed and fenced JSON -------------------------------------
block:
  let a = parsed("""Sure! Here is my order:
```json
{"stance":"lift","aggression":9,"say":"under it"}
```
Hope that helps.""")
  check a.stance == stanceLift, "a fenced, prose-wrapped reply did not parse"
  check a.aggression == 9, "the fenced reply's aggression was lost"
  check a.say == "under it", "the fenced reply's say was lost"

# --- an aggression given as a PERCENTAGE --------------------------------
block:
  let a = parsed("""{"stance":"charge","aggression":80}""")
  check a.aggression == 8,
    &"aggression 80 became {a.aggression}, want 8 (percentage form)"

# --- a bearing given in RADIANS ------------------------------------------
block:
  let a = parsed("""{"stance":"charge","aim":"bearing","bearing_deg":2.4}""")
  check a.bearingDeg == 138,
    &"bearing 2.4 rad became {a.bearingDeg} deg, want 138 (2.4 rad = 137.5)"

# --- circle_dir as a word ------------------------------------------------
block:
  check parsed("""{"circle_dir":"cw"}""").circleDir == -1,
    "circle_dir \"cw\" did not become -1"
  check parsed("""{"circle_dir":"ccw"}""").circleDir == 1,
    "circle_dir \"ccw\" did not become +1"
  check parsed("""{"circle_dir":"left"}""").circleDir == 1,
    "circle_dir \"left\" did not become +1"
  check parsed("""{"circle_dir":0}""").circleDir == 1,
    "circle_dir 0 did not take the positive sign"

# --- lead_ticks given in SECONDS ----------------------------------------
block:
  let a = parsed("""{"lead_ticks":0.5}""")
  check a.leadTicks == 12, &"lead_ticks 0.5 s became {a.leadTicks}, want 12"

# --- the two stance synonyms --------------------------------------------
block:
  check parsed("""{"stance":"push"}""").stance == stanceCharge,
    "stance \"push\" did not read as charge"
  check parsed("""{"stance":"hold"}""").stance == stanceBrace,
    "stance \"hold\" did not read as brace"
  check parsed("""{"stance":"  CIRCLE  "}""").stance == stanceCircle,
    "stance is not case- and whitespace-insensitive"

# --- an unknown stance keeps LAST TURN's, else charge -------------------
block:
  var previous = base
  previous.stance = stanceCentre
  check parsed("""{"aggression":5,"stance":"pirouette"}""",
    previous).stance == stanceCentre,
    "an unknown stance did not keep last turn's"
  check parsed("""{"aggression":5,"stance":"pirouette"}""",
    base, hasPrevious = false).stance == stanceCharge,
    "an unknown stance with no history did not fall back to charge"

# --- absent and out-of-range fields -------------------------------------
block:
  let a = parsed("""{"stance":"brace"}""", base, hasPrevious = false)
  check a.aim == aimFoe, "a missing aim did not default to foe"
  check a.aggression == 7, "a missing aggression did not default to 7"
  check a.leadTicks == 4, "a missing lead_ticks did not default to 4"
  check a.postureBias == biasAuto,
    "a missing posture_bias did not default to auto"
  let b = parsed("""{"aggression":99,"lead_ticks":900,"bearing_deg":-400}""")
  check b.aggression == 10, &"aggression 99 clamped to {b.aggression}, want 10"
  check b.leadTicks == 24, &"lead_ticks 900 clamped to {b.leadTicks}, want 24"
  check b.bearingDeg >= 0 and b.bearingDeg <= 359,
    &"bearing -400 became {b.bearingDeg}"
  let c = parsed("""{"posture_bias":"sideways"}""")
  check c.postureBias == biasAuto,
    "an unknown posture_bias did not repair to auto"

# --- a 300-character note is cut to 160 RUNES ---------------------------
block:
  let long = repeat("a", 300)
  let a = parsed("""{"stance":"charge","note":"""" & long & """"}""")
  check a.note.runeLen == MaxNoteRunes,
    &"a 300-character note became {a.note.runeLen} runes, want {MaxNoteRunes}"

# --- THE 4-BYTE EMOJI ON THE SAY BOUNDARY -------------------------------
block:
  ## The 48th and 49th characters are a 4-byte emoji. The cut MUST land on the
  ## RUNE boundary: a byte-truncated codepoint renders in a browser and then
  ## fails a strict UTF-8 parser, which is exactly the class of bug the rune
  ## rule exists to prevent.
  let say = repeat("x", 47) & "\u{1F980}\u{1F980}" & "tail"
  check say.runeLen > MaxSayRunes, "the emoji fixture is not over the cap"
  let cut = truncateRunes(say, MaxSayRunes)
  check cut.runeLen == MaxSayRunes,
    &"the rune cut produced {cut.runeLen} runes, want {MaxSayRunes}"
  check cut.validateUtf8() == -1,
    "the rune cut produced invalid UTF-8 — it landed mid-codepoint"
  check cut.endsWith("\u{1F980}"),
    "the rune cut did not keep the whole 4-byte codepoint"
  ## And it round-trips through the replay's own JSON path.
  var intent = base
  intent.note = say
  intent.say = cut
  let record = boundedIntentRecord(intent, 3, 0, 0)
  check record.runeLen <= MaxIntentRunes,
    &"the intent record is {record.runeLen} runes, cap {MaxIntentRunes}"
  let node = parseJson(record)
  check node["say"].getStr().validateUtf8() == -1,
    "the recorded say is not valid UTF-8"
  check ($node).validateUtf8() == -1,
    "the serialized record is not valid UTF-8"

# --- sanitizeSay strips control records' leading brace -----------------
block:
  check sanitizeSay("{not a record}") == "not a record",
    "sanitizeSay did not strip the braces a control record is told apart by"
  check sanitizeSay("caf\u00e9 \u2014 ok").len > 0,
    "sanitizeSay dropped everything from a non-ASCII line"

# --- a reply with NOTHING usable raises --------------------------------
block:
  var raised = false
  try:
    discard parsed("""{"weather":"fine"}""")
  except IntentError:
    raised = true
  check raised, "a reply with no usable field did not raise"
  raised = false
  try:
    discard parsed("I am afraid I cannot do that.")
  except IntentError:
    raised = true
  check raised, "a reply with no JSON object did not raise"

# --- the record vocabulary is bounded ----------------------------------
block:
  let detail = repeat("z", 500)
  let record = fallbackRecord(4, 1, 2, "timeout", detail)
  let node = parseJson(record)
  check node["detail"].getStr().runeLen <= MaxFallbackDetailRunes,
    "fallback.detail is over its rune cap"
  check node["cause"].getStr() == "timeout", "fallback.cause was lost"
  let reg = parseJson(registerRecord(0, 1, repeat("p", 200), "llm", "pusher"))
  check reg["policy"].getStr().runeLen <= MaxPolicyLabelRunes,
    "register.policy is over its rune cap"
  check not reg.hasKey("prompt"),
    "the register record leaked the seat's PROMPT into the replay"

if failures > 0:
  quit("test_intents: " & $failures & " failure(s)", 1)
echo "test_intents: ok"
