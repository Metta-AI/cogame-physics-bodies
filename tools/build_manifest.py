#!/usr/bin/env python3
"""Regenerate coworld_manifest_template.json.

The manifest inlines README.md and the three docs pages as `game.docs`, so it is
GENERATED rather than hand-maintained: editing a doc and forgetting the manifest
is exactly how `game.docs` goes stale. Run this after any change to README.md,
docs/RULES.md, docs/PROTOCOL.md or docs/ORDERS.md and commit both.

    python3 tools/build_manifest.py

tests/test_manifest.nim asserts every invariant the upload contract cares about
(num_agents everywhere, the results-schema key set, both protocols, the docs
being non-empty, the array bounds, the placeholder derivation), so a hand edit
that drifts from this script still fails CI rather than the upload.
"""

from __future__ import annotations

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

SOURCE_URL = "https://github.com/Metta-AI/cogame-physics-bodies/tree/main"
IMAGE = "{{PHYSICS_BODIES_IMAGE}}"

DESCRIPTION = (
    "Two four-legged robot bugs push each other out of a shrinking sumo ring; "
    "off-centre shoves spin you, and a bug that tips over cannot push for a "
    "second and a half."
)


def text(value: str) -> dict:
    return {"type": "text", "value": value}


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


PLAYER_PROTOCOL = """THE RING — the player wire contract.

GET /player?slot=<N>&token=<T> upgrades to a websocket. A slot with a
configured token demands exactly that token; a mismatch is refused 403 and the
socket is closed.

A seat sends ONE Sprite v1 chat message carrying its registration and then only
receives:

  {"type":"register","prompt":"<strategy text or empty>",
   "scripted":"pusher"|"anchor"|null,"policy":"<free label>"}

A non-empty `prompt` makes the seat an LLM seat (capped at 4000 runes at the
transport, truncated never rejected, and NEVER written to the replay or the
results). `scripted` names a published baseline. A seat that sets neither field,
or never registers at all, is `pusher`, and the server logs that out loud. The
registration is re-sent on a bounded schedule because joins are slot-sequential
and the lobby sends frames to a socket before it is admitted; the server HOLDS
an unappliable registration rather than dropping it.

SEATS SEND NO INPUTS. Every command byte is computed server-side by the
deterministic controller, so any input mask arriving on a player socket is
discarded. After each received frame the seat sends the Sprite v1 Ready packet
(0x85), which lets a fastMode server advance the tick as soon as both seats have
acknowledged the frame.

Each seat receives one binary Sprite v1 frame per tick. The game is
perfect-information on the physics: the frame carries the ring, the current rim
radius, both bugs with all eight feet, both tilt gauges and both round tallies.
Board labels carry ONLY the anonymous aliases BUG-1 and BUG-2.

Every 36 ticks (1.5 s) the seat is asked for ONE tactical order. The observation
it is given is in view coordinates (metres, origin bottom-left, y up, bearings
in degrees counter-clockwise from east, every number rounded to 2 decimals) and
carries: the turn index, the clock, the ring (centre, live radius, minimum
radius, when the shrink starts, the radius at the round clock), your bug and the
other bug in full physical detail (position, velocity, speed, heading, spin,
posture, effort, reach, tilt percent, grounded legs, down ticks, distance from
the centre, distance to the rim, all four foot positions), the contact state,
the match tallies and round log, the scoring rules, and your own last order.

HIDDEN from every seat with no exception: the other seat's order object, note,
say, prompt text, latency, policy kind, policy label and fallback state; which
entrant holds the other seat; any real player name; `perm`; `config.seed`; the
RNG state; the future start axes; and the variant name.

THE REPLY is a single JSON object beginning with '{':

  {"note":"<=160 runes","stance":"charge"|"brace"|"circle"|"lift"|"retreat"|"centre",
   "aim":"foe"|"centre"|"bearing","bearing_deg":0..359,"aggression":0..10,
   "posture_bias":"low"|"even"|"high"|"auto","lead_ticks":0..24,
   "circle_dir":-1|1,"say":"<=48 runes"}

Every field is REPAIRED rather than rejected: an unrecognised stance keeps last
turn's, else `charge`; a missing aim is `foe`; numbers are clamped; `note` and
`say` are truncated on RUNE boundaries. Parsing is tolerant of markdown fences,
prose prefixes, numeric strings, percentages for `aggression`, radians for
`bearing_deg`, "cw"/"ccw" for `circle_dir`, seconds for `lead_ticks`, and the
synonyms "push" (charge) and "hold" (brace). Only when no object with at least
one usable field can be recovered do a single retry and then the scripted
fallback fire — no failure mode leaves a bug uncommanded.

At aggression 10 the autopilot's rim guard is HALVED: an all-in push may put you
out. That is the documented trade, not a trap.
"""

GLOBAL_PROTOCOL = """THE RING — the spectator wire contract.

GET /global (and GET /replay) upgrades to a spectator websocket, which refuses
any request carrying player credentials. GET /healthz answers `healthy` and keeps
answering for a bounded ~20 s after the artifacts are written. GET /client/global
and GET /client/player serve the real broadcast page and neither opens the player
socket. GET /replay-data serves the recorded replay bytes.

A spectator receives the same binary Sprite v1 board stream plus the broadcast
chrome frame. The chrome rides the SAME binary channel as the board — as the
LABEL of a reserved never-drawn 1x1 sprite (id 4090) — because that is the only
channel that survives a hosted replay.

The chrome frame's keys are:

  t, mt, ph, lob, pl, sp, mx, st, lp, sk, ff, en, mm, bs, pov, teams, roster,
  events, turn, turns, turnTicks, pb, intents, lead, beats, lulls, over, hold

`teams` has exactly two keys, `bug1` and `bug2`, each carrying the live zero-sum
score, round wins, knockdowns suffered, ring-outs, knockouts, contacts, distance
from the centre, tilt percent, whether the bug is down, grounded legs and
posture. `roster` is spectator-side ONLY and is where the REAL policy names live,
one entry per seat with the bug it drives, its policy kind and its LLM/fallback
turn counts. `pb` carries the ring (centre, live radius, round-start radius,
minimum radius), the round (index, tick, clinch target, the round log), both bugs
with all four feet and their per-foot grounded/load flags, the last contact and
the two scores. `intents` carries the recent order records, which is where a
spectator SEES the LLM playing.

Derived beat events: phase, round_start, contact, shove, stagger, knockdown,
rim_slip, ring_out, round_end, match_point, turn_end, gameover. Only knockdown,
ring_out, round_end, match_point and the terminal verdict become SCRUBBER BEATS;
contact, shove, stagger and rim_slip fire dozens of times a round and would bury
the timeline.

Viewer input rides the same socket as Sprite v1 client messages: a chat message
`s:<tick>` seeks and single characters drive the transport (space, p, P, b, e, r,
f, '.', ',', and the speed keys 1 2 3 4 8 6).

THE REPLAY is binary, magic `COWLDPBD`, format version 1, game name
`physics-bodies`, game version `1`. It carries: the header; the resolved config
JSON (seed, `perm`, the whole match shape, every geometry and actuation constant,
the roster with real names); the joins and leaves; THE ACTION LOG — one command
byte per seat per tick, written on change only; the chat control records
(`register`, `intent`, `fallback`, `budget_guard`, `round`, `stop`, `result`),
each a JSON object told apart by a leading '{'; and ONE gameHash per tick. Only
`stop` is load-bearing at playback — every other fact re-derives from the action
log by re-running the same integer sim, and the hash chain is checked every tick
in the browser.

The replay is served by the STATIC wasm bundle
(`game.replay_viewer.bundle = static-replay-viewer`), never by a pod. The bundle
compiles the SAME `src/bodies/sim.nim` under emscripten and re-simulates every
frame from the recorded bytes.

`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON
object for a `.replay` path: protocol, gameVersion, seed, names, aliases, bodies,
policyKinds, tickCount, rounds, intents, fallbacks and the full results document.
"""

CONFIG_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens", "players"],
    "properties": {
        "tokens": {
            "type": "array",
            "items": {"type": "string"},
            "minItems": 1,
            "maxItems": 2,
        },
        "players": {
            "type": "array",
            "minItems": 1,
            "maxItems": 2,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"name": {"type": "string"}},
            },
        },
        "slots": {
            "type": "array",
            "minItems": 0,
            "maxItems": 2,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "alias": {"type": "string"},
                    "token": {"type": "string"},
                },
            },
        },
        "closedRoster": {"type": "boolean", "default": False},
        "seed": {"type": "integer", "minimum": 0},
        "num_agents": {"type": "integer", "minimum": 1, "maximum": 2,
                       "default": 2},
        "minPlayers": {"type": "integer", "minimum": 1, "maximum": 2,
                       "default": 2},
        "maxTicks": {"type": "integer", "minimum": 36, "maximum": 100000,
                     "default": 2160},
        "maxGames": {"type": "integer", "minimum": 1, "maximum": 4,
                     "default": 1},
        "turnTicks": {"type": "integer", "minimum": 1, "maximum": 6000,
                      "default": 36},
        "roundTicks": {"type": "integer", "minimum": 36, "maximum": 100000,
                       "default": 396},
        "resetTicks": {"type": "integer", "minimum": 0, "maximum": 6000,
                       "default": 36},
        "maxRounds": {"type": "integer", "minimum": 1, "maximum": 5,
                      "default": 5},
        "roundsToClinch": {"type": "integer", "minimum": 1, "maximum": 5,
                           "default": 3},
        "ringRadiusUm": {"type": "integer", "minimum": 600000,
                         "maximum": 3200000, "default": 3000000},
        "ringRadiusMinUm": {"type": "integer", "minimum": 400000,
                            "maximum": 3200000, "default": 1800000},
        "ringShrinkPerTickUm": {"type": "integer", "minimum": 0,
                                "maximum": 100000, "default": 4000},
        "shrinkStartTick": {"type": "integer", "minimum": 0, "maximum": 100000,
                            "default": 144},
        "knockdownsToLose": {"type": "integer", "minimum": 1, "maximum": 99,
                             "default": 3},
        "downTicks": {"type": "integer", "minimum": 1, "maximum": 600,
                      "default": 36},
        "turnBudgetMs": {"type": "integer", "minimum": 2000,
                         "maximum": 240000, "default": 16000},
        "attempt1Ms": {"type": "integer", "minimum": 1000, "maximum": 120000,
                       "default": 9000},
        "retryMs": {"type": "integer", "minimum": 1000, "maximum": 120000,
                    "default": 5000},
        "turnSpacingMs": {"type": "integer", "minimum": 0, "maximum": 120000,
                          "default": 6000},
        "wallClockBudgetSeconds": {"type": "integer", "minimum": 10,
                                   "maximum": 720, "default": 660},
        "lobbyJoinTimeoutTicks": {"type": "integer", "minimum": 24,
                                  "maximum": 20000, "default": 720},
        "startWaitTicks": {"type": "integer", "minimum": 0, "maximum": 20000,
                           "default": 120},
        "gameOverTicks": {"type": "integer", "minimum": 0, "maximum": 20000,
                          "default": 72},
        "fastMode": {"type": "boolean", "default": True},
        "showPlayerLabels": {"type": "boolean", "default": False},
        "model": {"type": "string"},
        "maxOutputTokens": {"type": "integer", "minimum": 64, "maximum": 8192,
                            "default": 900},
        "speed": {"type": "integer", "minimum": 1, "maximum": 16,
                  "default": 1},
    },
}


def seat_array(item_type: str) -> dict:
    return {
        "type": "array",
        "items": {"type": item_type},
        "minItems": 2,
        "maxItems": 2,
    }


RESULTS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["names", "scores", "win", "reason", "endRule", "roundsWon",
                 "rounds"],
    "properties": {
        "names": seat_array("string"),
        "aliases": seat_array("string"),
        "bodies": seat_array("integer"),
        "policyKinds": seat_array("string"),
        "scores": seat_array("number"),
        "win": seat_array("boolean"),
        "roundsWon": seat_array("integer"),
        "roundResults": {
            "type": "array",
            "minItems": 0,
            "maxItems": 5,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "round": {"type": "integer"},
                    "winner": {"type": "integer"},
                    "reason": {"type": "string"},
                    "ticks": {"type": "integer"},
                    "knockdowns": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "minItems": 2,
                        "maxItems": 2,
                    },
                },
            },
        },
        "ringOuts": seat_array("integer"),
        "knockouts": seat_array("integer"),
        "knockdownsSuffered": seat_array("integer"),
        "contacts": seat_array("integer"),
        "shoveImpulse": seat_array("number"),
        "meanEffortPct": seat_array("integer"),
        "llmTurns": seat_array("integer"),
        "fallbackTurns": seat_array("integer"),
        "rounds": {"type": "integer", "minimum": 0},
        "finalTick": {"type": "integer", "minimum": 0},
        "reason": {"type": "string",
                   "enum": ["complete", "deadline", "fault"]},
        "endRule": {"type": "string",
                    "enum": ["match_won", "full_time", "wall_clock",
                             "sim_fault", "host_error"]},
        "seed": {"type": "integer"},
    },
}

SLOTS = [{"alias": "BUG-1"}, {"alias": "BUG-2"}]
PLAYERS = [{"name": "BUG-1"}, {"name": "BUG-2"}]

VARIANTS = [
    {
        "id": "default",
        "name": "The Ring (2 bugs, best of 5)",
        "description": (
            "Two four-legged bugs, five rounds of 16.5 s in a shrinking 6 m "
            "ring, 60 order turns."
        ),
        "game_config": {
            "players": PLAYERS,
            "slots": SLOTS,
            "num_agents": 2,
            "minPlayers": 2,
            "maxTicks": 2160,
            "maxGames": 1,
            "maxRounds": 5,
            "roundsToClinch": 3,
            "turnTicks": 36,
            "roundTicks": 396,
            "resetTicks": 36,
            "turnSpacingMs": 6000,
            "turnBudgetMs": 16000,
            "attempt1Ms": 9000,
            "retryMs": 5000,
            "wallClockBudgetSeconds": 660,
            "lobbyJoinTimeoutTicks": 720,
            "fastMode": True,
        },
    },
    {
        "id": "blitz",
        "name": "Blitz (2 bugs, best of 3)",
        "description": (
            "Same ring and rules, three rounds, for cheap ladder rounds."
        ),
        "game_config": {
            "players": PLAYERS,
            "slots": SLOTS,
            "num_agents": 2,
            "minPlayers": 2,
            "maxTicks": 1296,
            "maxGames": 1,
            "maxRounds": 3,
            "roundsToClinch": 2,
            "turnTicks": 36,
            "roundTicks": 396,
            "resetTicks": 36,
            "turnSpacingMs": 6000,
            "turnBudgetMs": 16000,
            "attempt1Ms": 9000,
            "retryMs": 5000,
            "wallClockBudgetSeconds": 420,
            "lobbyJoinTimeoutTicks": 720,
            "fastMode": True,
        },
    },
]

CERTIFICATION = {
    "players": [{"player_id": "baseline"}, {"player_id": "baseline"}],
    "game_config": {
        "players": PLAYERS,
        "slots": SLOTS,
        "num_agents": 2,
        "minPlayers": 2,
        "seed": 5104773,
        "maxTicks": 1728,
        "maxRounds": 4,
        "roundsToClinch": 4,
        "maxGames": 1,
        "turnTicks": 36,
        "turnBudgetMs": 16000,
        "turnSpacingMs": 0,
        "wallClockBudgetSeconds": 180,
        "lobbyJoinTimeoutTicks": 480,
        "ringShrinkPerTickUm": 0,
        "fastMode": True,
    },
}


def build() -> dict:
    return {
        "$schema": (
            "https://raw.githubusercontent.com/Metta-AI/metta/main/packages/"
            "coworld/src/coworld/coworld_manifest_schema.json"
        ),
        "episode_timeout_minutes": 20,
        "tags": ["physics", "competitive", "continuous-control", "zero-sum",
                 "llm"],
        "game": {
            "name": "physics-bodies",
            "description": DESCRIPTION,
            "owner": "daveey@softmax.com",
            "replay_viewer": {"bundle": "static-replay-viewer"},
            "runnable": {
                "type": "game",
                "image": IMAGE,
                "run": ["/bin/physics-bodies"],
                "env": {
                    "ANTHROPIC_API_KEY_URI":
                        "secret://coworld/physics-bodies/anthropic_api_key"
                },
                "source_url": SOURCE_URL,
            },
            "config_schema": CONFIG_SCHEMA,
            "results_schema": RESULTS_SCHEMA,
            "protocols": {
                "player": text(PLAYER_PROTOCOL),
                "global": text(GLOBAL_PROTOCOL),
            },
            "docs": {
                "readme": text(read("README.md")),
                "pages": [
                    {"id": "rules.md", "title": "Rules",
                     "content": text(read("docs/RULES.md"))},
                    {"id": "protocol.md", "title": "Wire protocol",
                     "content": text(read("docs/PROTOCOL.md"))},
                    {"id": "orders.md", "title": "Writing a bug order",
                     "content": text(read("docs/ORDERS.md"))},
                ],
            },
        },
        "player": [
            {
                "id": "baseline",
                "type": "player",
                "name": "Ring Pusher Baseline",
                "description": (
                    "Scripted sumo bug: charge, shove whoever is nearer the "
                    "rim, lift on contact, and back off the edge. No LLM."
                ),
                "image": IMAGE,
                "run": ["/bin/physics-bodies-player"],
                "env": {"PLAYER_SCRIPTED": "pusher"},
                "source_url": SOURCE_URL,
                "resources": {
                    "requests": {"cpu": "100m", "memory": "64Mi"},
                    "limits": {"cpu": "1"},
                },
            }
        ],
        "variants": VARIANTS,
        "certification": CERTIFICATION,
    }


def main() -> None:
    out = ROOT / "coworld_manifest_template.json"
    out.write_text(json.dumps(build(), indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
