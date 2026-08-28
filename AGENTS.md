# Agent operating guide — cogame-physics-bodies (THE RING)

Orientation for coding agents. Gameplay rules live in
[docs/RULES.md](docs/RULES.md); the wire is
[docs/PROTOCOL.md](docs/PROTOCOL.md); the policy-facing schema is
[docs/ORDERS.md](docs/ORDERS.md); the design note that decided everything is
[docs/plans/2026-08-28-physics-bodies-design.md](docs/plans/2026-08-28-physics-bodies-design.md).
This file covers the things that are easy to get wrong.

## The determinism gate is inviolable

Replays are re-simulated by the **emscripten/wasm32** build of the same
`src/bodies/sim.nim` the **native amd64** server ran, and their per-tick
`gameHash` chains must match bit for bit. `tests/test_determinism.nim` is that
gate. If it fails, the physics or a build flag changed — **fix the code, never
the test.**

The rules that make it hold:

- **No floating point at all** under `src/bodies/{sim, ring, body, trig,
  sim_types, sim_config, sim_state}.nim`. No `sin`, `cos`, `arctan2`, `sqrt`,
  `pow`, `float`. The suite greps for them (comments stripped) and for
  `-ffast-math` in the build scripts. Floats stay legal in `control.nim`,
  `labels.nim`, `global.nim`, `broadcast.nim` and the pixie bakes, because
  neither the controller (recorded, not re-run) nor rendering enters `gameHash`.
- Every stored sim field is explicitly `int32`, `int64`, `uint8`, `bool` or an
  enum. **No bare `int` in a hashed field**: Nim's `int` is 64-bit natively and
  32-bit under `--cpu:wasm32`.
- **Every product or quotient of two sim quantities is computed in `int64`** and
  narrowed with an explicit truncating `div`. Nim's `div` truncates toward zero,
  which is what makes friction, yaw drag and the reflection arithmetic symmetric
  under negation.
- Trigonometry is the committed 32-entry `DirQ12` table plus `isqrt`, and
  nothing else. `tools/gen_trig_table.nim`-style regeneration is not needed: the
  table is checked in and re-derived from `math.cos`/`math.sin` by the tests.
- Randomness is ONE seeded splitmix64 stream and ONE proc, `ring.drawInt`.
  **Nothing calls `rand(`** — its `int` is 32-bit under wasm32. `rngDraws` is
  mixed into `gameHash`, so a divergence in HOW MANY draws a build took is
  caught at the tick it happens. Exactly **6** draws happen per episode
  (`perm`, then all five start axes), all at `t = 0`.

## EVERY field the config reads must be pinned in `configJson`

`sim_config.configJson` writes the resolved config into the replay header, and
playback re-reads it through the same `sim_config.update`. A field that is read
by `update` but written only inside the nested `geometry` block silently falls
back to *this build's* default at playback and diverges the hash chain the
moment the two differ. That is a real scar: the ring shrink law lived only in
`geometry` and every replay diverged at the first tick the ring moved.

`tests/test_manifest.nim` cross-checks the other half — every field `update`
reads must also appear in the manifest's `config_schema`, or it is not settable
at all.

## GameVersion

`GameVersion` lives in `src/bodies/sim_types.nim` with a **prepend-only**
changelog comment in the shape `GVnn (short rule name): HEADLINE`. Bump it for
any change to the hashed simulation, and re-record the golden fixture in the
same commit:

```bash
nim c -d:release --path:src -r tools/gen_golden_hashes.nim \
  > tests/data/golden_hashes.json
```

`tools/ci/check_gameversion.sh <base-ref>` refuses a number the base already
spent for a **different** rule — it diffs the changelog headline, because the
number alone cannot tell two claims apart.

## The chrome is INHERITED, not re-created

- `client/chrome_common.js` is `coworld-ctf`'s file **byte for byte**, and
  `tests/test_viewer.nim` pins its sha256. Every game-specific readout goes in
  the appended block at the end of `client/replay_broadcast.html`, under the
  `PHYSICS-BODIES additions to the inherited coworld-ctf chrome` banner.
- Every name in that block carries a **`pb` prefix**. The page's chrome alias
  block declares the shared beat builder with a hoisted `var markBeat`, so a
  game-block function of the same name is silently swallowed by it and the
  scrubber ends up with unlabelled markers that never seek.
- `relayout()` owns `--hudscale`, `--topband` and `--band` on `:root`. **No
  overlay may sit inside the transport band**; the endcard stops at
  `bottom: var(--band, 0px)` and every seek dismisses it.
- Every scrubber beat the block draws is a **labelled, clickable `<button>`**,
  and there is one `.beat-marker.<kind>` CSS rule per kind the sim emits. The
  test asserts both.
- `#viewpanel` (zoom bar + minimap), `#fpv` (the first-person inset) and
  `#povBadge` are **removed**: a sumo ring is a fixed arena and the 1920 × 1280
  board always fits the frame. `broadcast_core.js`'s zoom/pan/minimap code stays
  in the file, verbatim, simply never driven.

## The viewer's link flags and its JS bootstrap are a MATCHED PAIR

`replay-viewer/config.nims`, `replay-viewer/bodies_replay.nim`,
`replay-viewer/static_replay.js` and `replay-viewer/static_replay_worker.js` all
come from **one** starter, `coworld-ctf`. The worker declares `var Module = {}`
and waits for `Module.onRuntimeInitialized`, so the link flags must **never**
gain `-s MODULARIZE=1` or `-s EXPORT_NAME=…`. A mixture throws nothing, logs
nothing, and hangs on "Loading replay…" forever with every file present and 200.

`static_replay.js` sets `data-replay-loaded="true"` on its first drawn frame and
`data-replay-error` on failure. `tools/ci/viewer_smoke.mjs` — copied verbatim,
no substitutions — is what proves it in a real browser.

## The seat contract

- **Seats send no inputs.** Every command byte comes from
  `control.driveCommand` inside the game server; an input mask arriving on a
  player socket is discarded. That is why the seat may send the Sprite v1 Ready
  packet (`0x85`) without the dead-reckoning hazard it usually carries.
- A seat's chat is its **registration** and nothing else, and it is dropped in
  the websocket handler unless it parses as one — so a later chat line cannot
  overwrite a registration that has not been consumed yet.
- Registrations are **held**, not dropped, when the seat has no player index
  yet: joins are slot-sequential and the lobby sends frames to a socket before
  it is admitted.
- `PLAYER_PROMPT` is never written to the replay or the results. The replay gets
  a redacted `register` record: the policy label, the kind, and the baseline.

## Degrade, never hang

Every wait is bounded: the two batch deadlines, the inter-batch rate floor, the
outer per-turn deadline, `lobbyJoinTimeoutTicks`, the 660 s engine stop and the
bounded shutdown grace. Both seats' LLM calls go out as **one parallel batch**
per turn (`curly.makeRequests`) — seats are never queried sequentially, which is
the documented way to blow the wall clock. On two consecutive failures a seat
plays the `pusher` intent and a `fallback` record names the cause. **No failure
mode leaves a bug uncommanded.**

## Tuning

Three numbers are tunable — `rimGuardUm`, `chargeLeadTicks`, `liftEngageUm` —
and **the physics constants in docs/RULES.md are not**. If `pusher` cannot beat
`anchor`, or a ring-out stops deciding most rounds, re-run the sweep and commit
its pick:

```bash
nim c -d:release --path:src -r tools/tune_baselines.nim \
  > tools/ci/baseline_tuning.json
```

`tests/test_tuning.nim` asserts the shipped defaults still equal the recorded
pick; `tests/test_baselines.nim` re-measures the bars.

## Running the tests

CI runs every `tests/*.nim` twice, debug and release. Debug catches range and
overflow bugs; release catches codegen bugs a debug-only CI has shipped before.
`tests/test_perf.nim` and `tests/test_baselines.nim` are release-only (the
`NIM_TESTS_RELEASE_ONLY` repo variable).

```bash
for t in tests/*.nim; do
  nim r --hints:off --path:src "$t"
  nim r --hints:off -d:release --path:src "$t"
done
```

`nim.cfg` is **generated**, never committed: the one in a working tree pins that
machine's package paths. Rebuild it from `~/.nimby/pkgs` exactly as the
Dockerfile and `ci.yml` do.

## Regenerating the manifest

`coworld_manifest_template.json` inlines `README.md` and the three docs pages as
`game.docs`, so it is generated:

```bash
python3 tools/build_manifest.py
```

Commit both. `tests/test_manifest.nim` asserts every invariant the upload
contract cares about, so a hand edit that drifts still fails CI rather than the
upload.

## Debugging a hosted replay

Do not drive the Observatory UI. Download the bytes and read them:

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

`protocol` must read `physics-bodies/v1`. A champion seat's intents must carry
`source: "llm"` with varying `stance`/`aggression` — all-fallbacks or a constant
intent means the LLM never played.
