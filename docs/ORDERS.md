# Writing a bug order

A policy is just a prompt. Every **1.5 seconds** (36 ticks) your seat is asked
what its bug does next, and a deterministic autopilot runs that order 24 times a
second: it steers, it leads a moving target, and it keeps you off the rim unless
you tell it not to. You choose **what** to do and **how hard**.

## The reply

One JSON object and nothing else. Your reply MUST begin with `{`.

```json
{"note": "it is low and braced; circle to put the rim behind it before I commit",
 "stance": "circle", "aim": "foe", "bearing_deg": 0,
 "aggression": 5, "posture_bias": "even", "lead_ticks": 4, "circle_dir": 1,
 "say": "walking it to the edge"}
```

## Stances

| stance | what the autopilot does |
|---|---|
| `charge` | drive into the other bug where it WILL be in `lead_ticks`, and shove. The bread and butter. |
| `brace` | plant LOW facing the other bug and absorb. You barely move, you take less tilt, and a bug that charges a brace bounces. |
| `circle` | orbit the other bug at about 1.40 m in `circle_dir`, trying to end up with the rim behind IT and the centre behind YOU. |
| `lift` | close and get under it — the knockdown attempt. Slow, and it loads tilt onto you too. |
| `retreat` | back toward the ring centre, away from the other bug. |
| `centre` | walk to the ring centre and hold it. Wins a decision. |

## Fields, caps and repairs

| Field | Type | Cap / legal values | Repair when violated |
|---|---|---|---|
| `note` | string | **≤ 160 runes** | truncated to 160 runes |
| `stance` | string | closed enum `charge, brace, circle, lift, retreat, centre`, case-insensitive | unrecognised / missing → last turn's `stance`, else `charge` |
| `aim` | string | closed enum `foe, centre, bearing`, case-insensitive | unrecognised / missing → `foe` |
| `bearing_deg` | integer | finite, taken `mod 360` into `0..359` | non-finite / missing → last turn's value, else `0` |
| `aggression` | integer | finite, clamped `[0, 10]` | non-finite / missing → last turn's value, else `7` |
| `posture_bias` | string | closed enum `low, even, high, auto`, case-insensitive | unrecognised / missing → `auto` |
| `lead_ticks` | integer | finite, clamped `[0, 24]` | non-finite / missing → `4` |
| `circle_dir` | integer | `−1` or `+1`; any other value takes the sign (`0` → `+1`) | non-finite / missing → last turn's value, else `+1` |
| `say` | string | **≤ 48 runes** | truncated to 48 runes, then a printable-ASCII filter that also strips a leading `{` |

Three further caps on strings that reach the replay: `register.policy` ≤ 48
runes, any recorded error text (`fallback.detail`) ≤ 200 runes, and the whole
serialized `intent` record ≤ 480 runes. `register.prompt` is capped at 4000
runes **at the transport** (over-long is truncated, never rejected) and is never
written to the replay or the results.

**Truncation is on rune (Unicode codepoint) boundaries, never bytes.** Slicing a
string by byte index anywhere on the path to the replay is forbidden: a
byte-truncated multi-byte character renders in a browser and then fails a strict
UTF-8 parser.

## Parsing is tolerant

Markdown fences are stripped; the outermost balanced `{…}` is taken if the model
prefixed prose; numeric strings are accepted; `aggression` given as a percentage
(`0..100`) is divided by 10; `bearing_deg` given in radians (`|v| ≤ 6.3` with a
fractional part) is converted; `circle_dir` accepts `"cw"` / `"ccw"` /
`"left"` / `"right"`; `stance`, `aim` and `posture_bias` are matched
case-insensitively and with surrounding whitespace; `lead_ticks` given in
seconds (a decimal below 2) is multiplied by 24; `stance: "push"` reads as
`charge` and `"hold"` as `brace`.

Only when **no** object with at least one usable field can be recovered do the
retry and then the scripted fallback fire.

## What the autopilot does with your order

1. **Aim point.** `aim: "foe"` → the other bug's position plus its velocity
   times `lead_ticks`; `"centre"` → the ring centre; `"bearing"` → 4 m along
   `bearing_deg` from where you stand.
2. **Goal bearing** from the stance (see the table above).
3. **The rim guard, always, every stance.** The closer you are to the rim, the
   more the goal bearing is blended toward the ring centre. **At
   `aggression: 10` the guard is HALVED** — you may push yourself out. That is
   the trade, and it is the only way to order an all-in push.
4. **Posture.** `low`/`even`/`high` are taken literally. `auto` resolves as:
   `lift` stance and in contact → `lift`; `brace` stance → `low`; more than
   1.20 m apart → `high`; in contact → `low`; else `even`. The rim guard
   overrides to `low` when it is dominating.
5. **Effort**, continuous then duty-cycled: `3 × aggression / 10`, times 0.35
   for a `brace` that is not in contact, zero for a `brace` at a standstill, and
   tapered to zero inside 0.30 m of the goal for `centre` / `retreat`.
6. **Quantise** to the nearest of the 16 drive bearings and pack the byte.

## Two worked prompts

Both champions in this coworld are prompt policies. Their whole strategy is the
text below.

### `physics-bodies-ringcraft` — win on position, not on violence

```
Win on position, not on violence. Read dist_to_rim for BOTH bugs every turn and
treat the difference as the score of the fight: whoever is closer to the rim is
losing, whatever the round tally says.
Rules, in order. If YOUR dist_to_rim is under 0.60 m, stance "retreat" with aim
"centre" and aggression 8 for one turn - nothing else matters, you are one shove
from losing the round. Otherwise, if the other bug's dist_to_rim is under 0.90 m
AND you are in contact, stance "charge" with aim "foe", aggression 10,
lead_ticks 2, posture_bias "auto": this is the ring out and it is worth the
halved rim guard.
```

### `physics-bodies-toppler` — win by putting it on its back

```
Win by putting it on its back. Three knockdowns takes the round outright and a
downed bug cannot push, so every fall is also a free shove toward the rim.
Rules, in order. If YOUR tilt_pct is above 55, stance "brace", posture_bias
"low", aggression 3 for one turn and let your legs recover it. Otherwise, if the
other bug is DOWN (its down_ticks above 0), stance "charge", aim "foe",
aggression 10, lead_ticks 0: you have about a second of free pushing, spend all
of it driving it at the nearest rim.
```

## Field your own

```bash
coworld upload-policy coworld-physics-bodies:latest --name my-bug \
  --run /bin/physics-bodies-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Or run one of the published scripted baselines instead:
`PLAYER_SCRIPTED=pusher` (charge, shove whoever is nearer the rim, lift on
contact, back off the edge) or `PLAYER_SCRIPTED=anchor` (hold the middle, brace,
never initiate).
