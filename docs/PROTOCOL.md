# Wire protocol

## The player socket

`GET /player?slot=<N>&token=<T>` upgrades to a websocket. A slot with a
configured token demands exactly that token: a mismatch is refused with 403 and
the socket is closed.

A seat sends **one** Sprite v1 chat message carrying its registration, and then
only receives:

```json
{"type":"register","prompt":"<strategy text or empty>",
 "scripted":"pusher"|"anchor"|null,"policy":"<free label>"}
```

- `prompt` non-empty ⇒ this seat is an **LLM seat**. Capped at 4000 runes at the
  transport (truncated, never rejected) and **never** written to the replay or
  the results.
- `scripted` names a baseline. A seat that sets neither field — or never
  registers at all — is `pusher`, and the server says so out loud:
  `physics-bodies: seat N never registered; driving BUG-<i+1> with pusher`.
- `policy` is a free label, capped at 48 runes, and is the only part of the
  registration the replay records.

The registration is **re-sent** on the starter's schedule (10 re-sends, ~1 s
apart). Joins are slot-sequential, so a seat whose slot is not the next open one
is not admitted until the lower slots have joined — and the lobby sends frames to
a socket before it is admitted. The server **holds** an unappliable registration
rather than dropping it.

After each received frame the seat sends the Sprite v1 Ready packet (`0x85`).
That is legitimate here in a way it is not for an ordinary player client:
**seats send no inputs at all** — the server computes every command byte — so the
dead-reckoning hazard the packet can cause cannot arise, and a `fastMode` server
advances the tick as soon as both seats have acknowledged the frame. Any input
mask arriving on a player socket is **discarded**.

## The per-seat frame

One binary Sprite v1 message per tick. The game is **perfect-information on the
physics**: the ring is lit and both bodies are in it, so the frame carries the
ring, the current rim radius, both bugs with all eight feet, both tilt gauges and
both round tallies. Board labels carry only `BUG-1` / `BUG-2`;
`showPlayerLabels` is forced false on the player stream.

## The observation

Composed server-side and handed to the policy (the LLM user message, or the
scripted baseline's input — both read the identical object). Numbers are in
**view coordinates**: metres, origin bottom-left, y up, bearings in degrees
counter-clockwise from east, rounded to 2 decimals.

```json
{"turn": 24, "of": 60,
 "clock": {"tick": 864, "of": 2160, "round": 3, "of_rounds": 5,
           "round_tick": 0, "round_of": 396, "round_left_s": 16.5},
 "ring": {"centre": [4.80, 3.20], "radius_m": 3.00, "min_radius_m": 1.80,
          "shrink_starts_in_s": 6.0, "radius_at_round_end_m": 1.99},
 "you": {"alias": "BUG-1", "body": 0, "pos": [3.31, 4.28], "vel": [1.02, -0.41],
         "speed_m_s": 1.10, "heading_deg": 338.0, "spin_dps": -12.4,
         "posture": "even", "effort": 2, "reach_m": 0.46,
         "tilt_pct": 18, "grounded_legs": 4, "down_ticks": 0,
         "dist_from_centre_m": 1.85, "dist_to_rim_m": 1.15,
         "feet": [[3.77, 4.11], [3.14, 3.82], [2.85, 4.45], [3.48, 4.74]]},
 "foe": {"alias": "BUG-2", "body": 1, "pos": [5.94, 2.40], "vel": [-1.31, 0.52],
         "speed_m_s": 1.41, "heading_deg": 158.0, "spin_dps": 5.1,
         "posture": "low", "effort": 3, "reach_m": 0.62,
         "tilt_pct": 41, "grounded_legs": 4, "down_ticks": 0,
         "dist_from_centre_m": 1.42, "dist_to_rim_m": 1.58,
         "bearing_from_you_deg": 342.0, "range_m": 2.90, "closing_m_s": 2.31},
 "contact": {"in_contact": false, "normal_deg": null,
             "your_impulse_last_turn": 0.00, "their_impulse_last_turn": 0.00},
 "match": {"rounds_won": {"you": 1, "foe": 1}, "to_clinch": 3,
           "knockdowns_this_round": {"you": 0, "foe": 0},
           "ring_outs": {"you": 1, "foe": 0},
           "round_log": [{"round": 1, "winner": "BUG-1", "reason": "ring_out"}]},
 "rules": {"knockdowns_to_lose": 3, "round_win_points": 1.0,
           "ring_out_bonus": 0.25, "knockout_bonus": 0.25, "zero_sum": true,
           "note": "a leg whose foot is over the rim has no floor: no push, no balance recovery"},
 "your_last_intent": {"stance": "charge", "aim": "foe", "bearing_deg": 0,
                      "aggression": 8, "posture_bias": "auto", "lead_ticks": 6,
                      "circle_dir": 1}}
```

**Hidden from every seat, with no exception:** the other seat's intent object,
`note`, `say`, prompt text, latency, policy kind, policy label and fallback
state — a seat sees the other *body's* physical state and nothing about the
*mind* driving it. (`foe.posture` and `foe.effort` are the physical consequences
of last tick's byte, visible on the board to any spectator, so withholding them
would be a lie about the world.) Also hidden: which entrant holds the other
seat, any real player name, `perm`, `config.seed`, the RNG state, the future
start axes, and the variant name.

## The reply

See [ORDERS.md](ORDERS.md) for the schema, the per-field caps and the repair
table.

## The global socket

`GET /global` (and `GET /replay`) upgrades to a spectator websocket, which
refuses any request carrying player credentials. It receives the same binary
sprite stream plus the broadcast chrome frame, which rides the SAME binary
channel as the board — as the label of a reserved never-drawn 1×1 sprite (id
4090). That is the only channel that survives a hosted replay.

The chrome frame's keys above the fold are the starter's and are consumed by the
byte-identical `client/chrome_common.js`; everything game-specific is under `pb`
and `intents`.

```json
{"t": 864, "mt": 2160, "ph": "playing", "lob": 0, "pl": true, "sp": 1,
 "mx": 2160, "st": 0, "lp": false, "sk": false, "ff": false, "en": true,
 "mm": -1, "bs": 2, "pov": -1,
 "teams": {"bug1": {"score": 2.75, "rounds": 2, "knockdowns": 1,
                    "ringOuts": 1, "distFromCentre": 1.85, "tilt": 18,
                    "down": false},
           "bug2": {"…": "…"}},
 "roster": [{"s": 0, "name": "daveey", "team": "bug2", "alias": "BUG-2",
             "body": 1, "kind": "llm", "rounds": 1, "knockdowns": 4,
             "contacts": 41, "effortPct": 64}],
 "events": [{"k": "knockdown", "t": 851, "body": 1, "count": 2}],
 "turn": 24, "turns": 60, "turnTicks": 36,
 "pb": {"ring": {"centre": [4.80, 3.20], "r": 2.31, "r0": 3.00, "rmin": 1.80},
        "round": {"index": 3, "of": 5, "tick": 0, "of_ticks": 396,
                  "toClinch": 3, "log": []},
        "bugs": [{"i": 0, "p": [3.31, 4.28], "v": [1.02, -0.41],
                  "heading": 338.0, "spin": -12.4, "posture": "even",
                  "effort": 2, "drive": 11, "tilt": 18, "down": 0,
                  "grounded": 4,
                  "feet": [{"p": [3.77, 4.11], "g": true, "load": 0}]}],
        "contact": {"on": false, "point": null, "normal": null,
                    "impulse": 0.0, "lift": false},
        "score": {"bug1": 2.75, "bug2": -2.75}},
 "intents": [{"turn": 24, "seat": 0, "alias": "BUG-2", "body": 1,
              "source": "llm", "stance": "lift", "aggression": 9,
              "note": "…", "say": "getting under it"}],
 "lead": {"teams": ["bug1", "bug2"], "pts": [[0, 0, 0]]},
 "beats": [{"t": 213, "k": "ring_out"}],
 "lulls": [[430, 590]],
 "over": {"winner": "bug1", "draw": false, "timeLimit": false,
          "endRule": "match_won", "reason": "complete", "score": 2.75,
          "ticks": 1608, "teams": {"bug1": {"rounds": 3}}},
 "hold": 3}
```

There are exactly **two** `teams` keys (`bug1`, `bug2`) — this is a two-sided
zero-sum game — so the chrome's plate loop renders one plate per side. `roster`
carries the **real policy names** and is spectator-side only.

Viewer input rides the same socket as Sprite v1 client messages: a chat message
`s:<tick>` seeks, and single characters drive the transport (space, `p`, `P`,
`b`, `e`, `r`, `f`, `.`, `,`, and the speed keys `1 2 3 4 8 6`).

## Other routes

| Route | Serves |
|---|---|
| `GET /healthz` | `healthy` (and keeps answering for ~20 s after the artifacts are written) |
| `GET /client/global`, `GET /client/player`, `GET /client/replay` | the real broadcast page; neither `/client/` route opens the player socket |
| `GET /replay-data` | the recorded replay bytes, once written |
| `GET /client/font.ttf`, `/client/art/**` | the page's own assets |

## The replay

Binary, magic **`COWLDPBD`**, format version 1, game name `physics-bodies`,
game version `1`.

| Content | Carries |
|---|---|
| header | magic, format version, game name/version, timestamp |
| config JSON | `seed`, `perm`, `num_agents`, the whole match shape, every geometry and actuation constant, `players[].name` (**real names**), `slots[].alias`, `fastMode` |
| joins / leaves | per seat: name (real policy name), slot, token |
| inputs | **the action log**: one command byte per seat per tick, written on change only |
| chats | `register` / `intent` / `fallback` / `budget_guard` / `round` / `stop` / `result` control records — each a JSON object, told apart from anything else by a leading `{` |
| hashes | one `gameHash` per tick — the integrity chain the viewer re-checks |

Only **`stop`** is load-bearing at playback: it is the one fact playback cannot
re-derive from the action log, and it is applied by the same proc the recording
side used. `round` records re-derive inside `bankRound`, so re-applying one would
double-bank it.

`tools/replay_summary.py` (Python 3 stdlib only, no Nim, no Docker) prints one
strict-UTF-8 JSON object for a `.replay` path:

```bash
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

## Tier-2 events

With `COGAME_EVENTS_URI` set (file:// only), the game writes JSON lines — one row
per event (`contact`, `shove`, `stagger`, `knockdown`, `rim_slip`, `ring_out`,
`round_end`, `intent`, `phase`) plus a mandatory trailing summary row carrying
`type`, `ticks`, `events` and `gameVersion`.
