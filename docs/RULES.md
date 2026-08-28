# THE RING — rules

Two four-legged robot bugs stand in a circular clay ring 6.00 m across and try
to put each other **out of it**. Best of five rounds. Strictly zero sum.

## Seats

`num_agents` is **2**. One seat drives one bug. In-game a bug is called
**`BUG-1`** or **`BUG-2`** and nothing else; real policy names exist only
spectator-side (the scorebug, the endcard, `results.names`).

Seat `s` drives bug `perm[s]`, where `perm` is a permutation of `0..1` drawn
once at `t = 0` from `config.seed`. `perm` is written into the replay config
JSON and into `results.bodies`, and is never visible to any seat.

## The world

| Quantity | Unit |
|---|---|
| Position, length, radius | micrometres (µm), `int32` |
| Velocity, per-tick impulse | µm per tick, `int32` |
| Direction index | 1/32 turn, `0..31`, index `d` = bearing `11.25° · d` counter-clockwise from east |
| Heading | milli-index, `0 … 31999` (1000 = one direction index) |
| Yaw rate | milli-index per tick |
| Tilt | milli-tip, `0 … 1000` |
| Unit vectors | Q12 (4096 = 1.0), from the committed `DirQ12` table |
| Score accumulators | micro-points (1e-6 of a score point), `int64` |

The whole simulation runs in **integers**. Replays are re-simulated by the
emscripten/wasm32 build of the same Nim module the native amd64 server ran, and
their per-tick `gameHash` chains must match bit for bit: integers make that true
by construction rather than by an argument about two builds of libm agreeing.
`src/bodies/{sim,ring,body,trig,sim_types,sim_config,sim_state}.nim` contain no
floating point at all (grep-enforced in CI).

```
ArenaW              = 9_600_000 µm  (9.60 m)
ArenaH              = 6_400_000 µm  (6.40 m)
RingCentre          = (4_800_000, 3_200_000)     -- view (4.80, 3.20) m
RingRadius0         = 3_000_000 µm  (3.00 m)     -- 6.00 m across at round start
RingRadiusMin       = 1_800_000 µm  (1.80 m)     -- the shrink floor
ShrinkStartTick     = 144            (6.0 s into a round)
ShrinkPerTick       = 4_000 µm/tick  (0.096 m/s)
TorsoRadius         =   300_000 µm  (0.30 m)
FootRadius          =   110_000 µm  (0.11 m)
LegCount            = 4 ; LegBaseIdx = [0, 8, 16, 24]
ReachByPosture      = [620_000, 460_000, 300_000, 540_000] µm  -- low/even/high/lift
StartRadius         = 1_900_000 µm  (1.90 m from centre; the bugs start 3.80 m apart)
```

**View coordinates** — the only coordinates a policy or the chrome ever sees —
are metres with the origin at the arena's **bottom-left** corner, x right,
y **up**. Bearings are degrees counter-clockwise from east (`0° = right`,
`90° = up`), speeds are m/s, and every number shown to a policy is rounded to
2 decimals.

## The body

One rigid torso disc plus four legs. There is no joint solver, no inverse
kinematics and no ragdoll: five collision discs and one leg kinematic that turns
the command byte into forces. This is a **reduction**, stated as one.

- **Torso**: centre, velocity, heading, yaw rate, tilt, `downTicks`, radius
  `TorsoRadius`.
- **Four legs** mounted at torso-relative direction offsets `[0, 8, 16, 24]`.
  Leg `k`'s reach is a pure function of the current posture; its foot centre is
  `p + reach · DirQ12[(heading + LegBaseIdx[k]) mod 32] / 4096`.
- **Grounded**: leg `k` is grounded iff its foot is inside `ringRadiusNow` and
  `downTicks == 0`. **A foot over the rim finds no floor** — no push, no balance
  recovery. Standing near the edge costing you traction and stability is the
  whole tactical spine of the game.

## Actuation

```
ThrustUnit          =     3_600 µm/tick^2  -- effort 3, 4 legs grounded, posture 'even'
TractionMulPct      = [130, 100,  70,  90]
FricNumPer1024      = [ 40,  26,  16,  32] -- v -= (v * FricNum) div 1024, every tick
MaxSpeedByPosture   = [ 95_000, 135_000, 165_000, 115_000] µm/tick
MaxBodySpeedHard    =   260_000 µm/tick    -- the post-contact clamp and the fault guard
YawGainPct          = [ 70, 100, 130,  90]
YawAccelMilli       =       120 ; MaxYawMilli = 900 ; YawDragNumPer1024 = 180
Restitution         =     1_200 (Q12; 0.293 rebound)
ShoveUnit           =     6_200 µm/tick ; ShoveMulPct = [110, 100, 80, 150]
TipImpulseThreshUm  =    26_000 ; TipPerUmDiv = 40
LiftTipMilli        =        60 ; LiftSelfTipMilli = 20
TipRecvMulPct       = [ 60, 100, 140, 100]
SpinTipMilli        =       600 ; TipRecoverMilli = 26 ; TipDown = 1_000
DownTicks           =        36  (1.5 s) ; KnockdownsToLose = 3
CentreTieUm         =    20_000
```

**Terminal speeds are set by friction, not by the clamp.** `low`
3600·130/100 · 1024/40 = 119 808 (clamped to 95 000), `even` 141 784 (clamped to
135 000), `high` 161 280 (under its 165 000 clamp), `lift` 103 680 (under its
115 000 clamp).

## The command byte

One `uint8` per seat per tick — the recorded action, and the whole action stream.

```
drive   = int(cmd) div 16        # 0..15, a drive BEARING; direction index = 2*drive
posture = (int(cmd) div 4) mod 4 # 0 = low, 1 = even, 2 = high, 3 = lift
effort  = int(cmd) mod 4         # 0..3, leg load
```

16 × 4 × 4 is exactly 256, so the byte uses its whole range: no value is
reserved and no value needs repair. The torso heading follows a yaw servo toward
the drive bearing (a bug turns to face where it pushes) and leg reach is a pure
function of posture. Force magnitudes between the four effort levels are reached
by **duty-cycling** across ticks with an error-diffusion accumulator: 24 bytes a
second is where the continuity lives, not in one byte's amplitude.

## Time and rounds

```
TargetFps = ReplayFps = 24 ; there are NO substeps
turnTicks       =   36   (1.5 s)   -- the decision cadence; 60 turns per episode
roundTicks      =  396   (16.5 s)
resetTicks      =   36   (1.5 s)   -- the hold between rounds
maxRounds       =    5 ; roundsToClinch = 3   (best of five)
maxTicks        = 2160   (90.0 s)  = 5 x (396 + 36) = 60 x 36
```

Turn boundaries live on the **global** tick grid and are not re-aligned when a
round ends early: re-aligning would make the wall-clock budget a function of how
the rounds went, and the budget is what the platform kills you for.

**Round start.** The ring is full; both bugs are placed at rest on a **seeded
start axis** at `StartRadius` from the centre, facing each other. Bug 0 takes
the drawn axis on even rounds and the opposite end on odd rounds (the **end
swap**), so no seat owns a side. The ring then shrinks by `ShrinkPerTick` per
tick once the round tick passes `ShrinkStartTick`, floored at `RingRadiusMin`.

## Resolution order (exact, every tick)

1. **Turn boundary.** On `t mod 36 == 0` while playing, the collected intents
   become each seat's standing intent and one `intent` chat record per seat goes
   into the replay. The intent is **not** hashed — the command bytes it produces
   are recorded, and those are what the viewer replays.
2. **Controller compile**, in **body index order** (never seat order).
   `driveCommand` is a pure function of the sim state, the body index, its
   seat's intent and the tick, and returns the byte written with
   `writeInputMaskChange`.
3. **Ring geometry.** `ringRadiusNow`, then leg reach, the four foot positions
   and `groundedCount` for both bodies.
4. **Yaw**, body index order: servo toward the drive bearing, drag, clamp. A
   prone body skips the self-driven term but keeps drag and the clamp.
5. **Traction and linear dynamics**: a prone body pushes with nothing and scrubs
   speed fast; thrust scales with effort, posture traction and `groundedCount`;
   then friction, the per-posture speed clamp, and `p += v`.
6. **Body–body contacts.** Ten disc pairs in one fixed order, every test
   **swept**. Positional split (a prone body takes the whole penetration),
   normal impulse (equal masses), then the **shove**: a grounded foot with
   effort pushes the other bug away along the contact normal. The momentum comes
   from the **floor**, not from the receiver, so a well-planted pusher
   (`groundedCount == 4`) takes **zero** recoil — which is exactly why bracing on
   all four legs before you shove is the right play. Then contact torque (an
   off-centre hit spins you), tilt load scaled by the receiver's posture, and the
   `MaxBodySpeedHard` clamp.
7. **Tilt and knockdown.** Spin above `SpinTipMilli` erodes your own stability;
   grounded legs recover it; at full tilt the bug goes **Down** for 36 ticks,
   folds its legs in, cannot push and cannot recover tilt.
8. **Arena box clamp** — only reachable after a ring-out, so no coordinate can
   leave the world.
9. **Round end**, first to fire: **ring-out** (a torso centre outside
   `ringRadiusNow`; both outside → the farther one loses, within `CentreTieUm` →
   a draw); **knockout** (three knockdowns in one round); **round clock** (fewer
   knockdowns wins, else closer to the centre, else a draw).
10. **Score bank** — one proc, `bankRound`, identical on record and on playback.
11. **Hash** — one `gameHash` per tick.
12. **Episode end**: a clinch (`complete/match_won`), the wall clock
    (`deadline/wall_clock`), full time (`complete/full_time`), or a tripped
    invariant (`fault/sim_fault`).

There is no rescue rule, no difficulty ramp and no stalling timer beyond the
shrinking ring.

## Scoring

```
RoundWinMicro   = 1_000_000        (+1.000 for winning a round)
bonus(ring_out) =   250_000        (+0.250 -- the clean win)
bonus(knockout) =   250_000        (+0.250 -- three falls)
bonus(decision) =         0
draw            = banked to nobody

raw[s]   = roundMicro[perm[s]] / 1_000_000
score[s] = raw[s] - raw[1 - s]
```

**Higher is better; the two scores sum to exactly 0.000.** There is no time
bonus, no thrust cost and no participation term. The reachable range is
`[−3.750, +3.750]` (a 3–0 sweep of ring-outs).

| Outcome | rounds | raw[0] | raw[1] | score |
|---|---|---|---|---|
| 3–0 sweep, all ring-outs | 3 | 3.750 | 0.000 | **+3.750 / −3.750** |
| 3–1, two ring-outs + one knockout, one decision lost | 4 | 3.750 | 1.000 | **+2.750 / −2.750** |
| 3–2, mixed | 5 | 2.750 | 2.250 | **+0.500 / −0.500** |
| 2–2 with one draw, full time | 5 | 2.500 | 2.500 | **0.000 / 0.000** |
| 2–3 the other way, all decisions | 5 | 2.000 | 3.000 | **−1.000 / +1.000** |
| Five drawn rounds | 5 | 0.000 | 0.000 | **0.000 / 0.000** |

The league ranks by **Elo (1000 / K 32)** driven by `results.win`, tie-broken by
mean `results.scores`. Elo is correct here: this is a strictly two-sided zero-sum
head-to-head with a decided winner in every non-drawn episode.

## End conditions

`results.reason` is a closed enum of exactly three values; `results.endRule`
carries the detail.

| `reason` | `endRule` | When |
|---|---|---|
| `complete` | `match_won` | A bug reaches `roundsToClinch` round wins. The normal good ending. |
| `complete` | `full_time` | `maxRounds` played, or `maxTicks` reached, with no clinch. |
| `deadline` | `wall_clock` | `wallClockBudgetSeconds` (660) elapsed first. The sim stops at that tick, banks the round in progress as a **draw**, scores the state as it stands and writes a complete replay up to that tick. |
| `fault` | `sim_fault` | A step-12 invariant guard tripped. Partial replay written. |
| `fault` | `host_error` | An unexpected server-side exception. Best-effort artifacts written. |

A seat that never connects does **not** end the episode: the lobby budget
expires, the no-show is reported to `COGAME_PLAYER_FAILURE_URI`, its bug is
driven by the `pusher` baseline for the whole run, and the match plays to a
normal ending.
