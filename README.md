# cogame-physics-bodies — THE RING

Two four-legged robot bugs push each other out of a shrinking sumo ring.
Off-centre shoves spin you, and a bug that tips over cannot push for a second
and a half.

Each bug is a 0.60 m torso disc walking on four legs. It pushes by loading the
leg behind it — **a leg that has floor under it**. A foot over the rim finds no
floor: standing near the edge costs you push and costs you balance. A shove that
lands off the opponent's centre line **spins** it, and spin, height and being
levered under all fill a **tilt gauge**; at full tilt a bug **falls over** and
lies there for 1.5 s, unable to push and shovable while prone. You lose the round
the instant your torso centre crosses the rim, or on your third knockdown — and
the rim comes toward you as the round runs, from 3.00 m down to 1.80 m.

Best of five rounds. Strictly zero sum: `score[0] + score[1] == 0.000`, and the
reachable range is ±3.750.

- **Rules and every constant**: [docs/RULES.md](docs/RULES.md)
- **Wire protocol**: [docs/PROTOCOL.md](docs/PROTOCOL.md)
- **Writing a bug order** (the reply schema and both champion prompts):
  [docs/ORDERS.md](docs/ORDERS.md)
- **Design note**:
  [docs/plans/2026-08-28-physics-bodies-design.md](docs/plans/2026-08-28-physics-bodies-design.md)

## A policy is just a prompt

Every 1.5 seconds your seat is asked, in plain English, what its bug does next;
a deterministic autopilot compiles the answer into one command byte 24 times a
second. Both champions in this coworld are prompt policies — their whole
strategy is the text in `tools/ci/policies.json` — and both fillers are scripted
baselines from the SAME image, switched by one environment variable:

```bash
# an LLM seat
PLAYER_PROMPT="Win on position, not on violence. …"  /bin/physics-bodies-player
# a scripted seat
PLAYER_SCRIPTED=pusher                               /bin/physics-bodies-player
```

## Layout

```
src/physics_bodies.nim          the game server entrypoint (seed randomization)
src/physics_bodies_player.nim   the thin seat registrar -> /bin/physics-bodies-player
src/bodies/
  sim_types.nim   constants, enums, records; GameVersion
  trig.nim        the committed DirQ12 table + isqrt — the ONLY trigonometry
  body.nim        the leg kinematic and the command-byte decode
  ring.nim        ring geometry, the shrink law, the seeded draws, swept contacts
  sim.nim         the step loop (§Resolution order); re-exports the sim modules
  sim_config.nim  GameConfig lifecycle, update(), configJson()
  sim_state.nim   gameHash, the lobby, the tier-2 event sink, the guards
  roster.nim      join/auth and the 21-key results document
  labels.nim      view-space conversion and sprite labels
  intents.nim     the order schema, the tolerant parser, the rune discipline
  control.nim     driveCommand — one intent -> one command byte per tick
  baselines.nim   the per-seat observation + `pusher` and `anchor`
  llm.nim         the Bedrock/Anthropic transport
  decide.nim      the per-turn ONE PARALLEL BATCH, two deadlines, budget guard
  global.nim      the board renderer (pixie bakes + sprite protocol)
  broadcast.nim   the chrome frame and the beat derivation
  replays.nim     the COWLDPBD codec wrapper, keyframes, the precompute walk
  replay_runtime.nim  the shared native/wasm playback runtime
  events.nim      the tier-2 JSON-lines wire format
  wire_constants.nim  the one-source JS constants block
  server.nim      mummy HTTP/websockets, the 24 Hz loop, the artifact writes
replay-viewer/    the emscripten static bundle (same sim module, in the browser)
client/           the broadcast chrome (chrome_common.js is the starter's, byte for byte)
tests/            15 suites; the determinism gate is inviolable
tools/            the build hook, CI helpers, the replay forensics script
```

## Build and run

The canonical build recipe is the [Dockerfile](Dockerfile). Locally:

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
# rebuild nim.cfg from THIS machine's package tree (the committed one pins the
# author's paths and is wrong on every other host)
rm -f nim.cfg
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim c -d:release --path:src -o:physics-bodies src/physics_bodies.nim
nim c -d:release --path:src -o:physics-bodies-player src/physics_bodies_player.nim
```

Every test twice, exactly as CI does:

```bash
for t in tests/*.nim; do
  nim r --hints:off --path:src "$t"           # debug: range + overflow checks
  nim r --hints:off -d:release --path:src "$t"
done
```

## The determinism gate

Replays are re-simulated by the **wasm32** build of the same `src/bodies/sim.nim`
the **native amd64** server ran, and their per-tick `gameHash` chains must match
bit for bit. That is why the hashed modules contain **no floating point at all**
(`tests/test_determinism.nim` greps for it), why the only trigonometry is a
committed 32-entry table plus an integer square root, and why every product or
quotient of two sim quantities is computed in `int64` and narrowed with an
explicit truncating `div`.

If the gate fails, the physics or a build flag changed. Fix the code, never the
test.

## CI

- **`test`** — every `tests/*.nim` in debug and release.
- **`docker-smoke`** — builds the production image and runs one real episode in
  raw Docker from the certification fixture (`SMOKE_SEATS=2`,
  `SMOKE_REQUIRE_REPLAY_JSON=0` because the replay is binary), then uploads the
  replay it produced.
- **`wasm-viewer`** — builds the static bundle through the pinned
  `emscripten/emsdk:4.0.15` container and then **opens it in headless chromium**
  against that replay. A bundle that builds and never renders is as broken as one
  that does not build.

## Forensics

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

`protocol` must read `physics-bodies/v1`; `results.reason` must be `complete` (or
the declared-acceptable `deadline`); a champion seat's intents must carry
`source: "llm"` with varying `stance`/`aggression`.

## Licence

MIT. Font licence in [data/FONT_LICENSE.txt](data/FONT_LICENSE.txt).
