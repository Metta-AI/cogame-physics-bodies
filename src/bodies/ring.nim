## The ring: its fixed geometry, its shrink law, the seeded seat/body
## permutation and per-round start axis (with the end swap), and the swept
## disc-contact test the sumo core runs on ten disc pairs a tick.
##
## There is no map generator, no `mapSpec`, no wall mask and no procedural
## terrain in this coworld: one circular ring, centred, shrinking on a fixed
## law, every round.
##
## No floating point (grep-enforced, tests/test_determinism.nim 2d).

import sim_types, trig

# ---------------------------------------------------------------------------
#  The seeded stream
# ---------------------------------------------------------------------------
# ONE stream, one draw proc. Nothing anywhere calls `rand(int)`: its `int` is
# 32-bit under `--cpu:wasm32` and 64-bit natively, which is ctf's documented
# determinism hazard. splitmix64 is committed here rather than taken from
# std/random so the state is a plain `uint64` that flatty can serialize into a
# replay keyframe, and so the arithmetic is identical on both builds.

proc seedStream*(seed: int): uint64 =
  ## The initial state for one episode's stream. Mixed, so two adjacent seeds
  ## do not produce two adjacent first draws.
  var z = uint64(seed) * 0x9E3779B97F4A7C15'u64 + 0x2545F4914F6CDD1D'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc nextRandom(state: var uint64): uint64 =
  ## One splitmix64 step, entirely in the `uint64` domain.
  state = state + 0x9E3779B97F4A7C15'u64
  var z = state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc drawInt*(state: var uint64, draws: var int32, lo, hi: int32): int32 =
  ## The ONLY draw in the sim. `draws` is a monotonic counter mixed into
  ## `gameHash`, so a divergence in HOW MANY draws a build took is caught at
  ## the tick it happens rather than as a mystery mismatch later. There is no
  ## rejection sampling, so this cannot loop.
  inc draws
  if hi <= lo:
    return lo
  let span = uint64(int64(hi) - int64(lo) + 1)
  int32(int64(lo) + int64(nextRandom(state) mod span))

# ---------------------------------------------------------------------------
#  Geometry
# ---------------------------------------------------------------------------

proc ringRadiusAt*(config: GameConfig, roundTick: int32): int32 =
  ## The shrink law, a PURE function of the round tick — so it re-derives
  ## identically in the browser and is never a wall-clock fact.
  let
    r0 = int32(config.ringRadiusUm)
    rmin = int32(config.ringRadiusMinUm)
    per = int32(config.ringShrinkPerTickUm)
    startAt = int32(config.shrinkStartTick)
    elapsed = max(0'i32, roundTick - startAt)
  max(rmin, int32(int64(r0) - int64(elapsed) * int64(per)))

proc distFromCentre*(body: Body): int32 =
  distUm(body.px, body.py, RingCentreX, RingCentreY)

proc distToRim*(body: Body, ringRadiusNow: int32): int32 =
  ## Never negative: a body past the rim reads 0 to a policy, and the ring-out
  ## predicate is what tells it the round is over.
  max(0'i32, ringRadiusNow - body.distFromCentre())

proc outsideRing*(body: Body, ringRadiusNow: int32): bool =
  body.distFromCentre() > ringRadiusNow

# ---------------------------------------------------------------------------
#  Seeded seating and the per-round start axis
# ---------------------------------------------------------------------------

proc drawPerm*(state: var uint64, draws: var int32): array[BodyCount, int32] =
  ## The seat -> body permutation, drawn ONCE at t = 0 from the seeded stream.
  ## Never visible to any seat; written into the replay config JSON (the
  ## viewer needs it to map real names onto bodies) and into `results.bodies`.
  result = [0'i32, 1'i32]
  if drawInt(state, draws, 0, 1) == 1:
    result = [1'i32, 0'i32]

proc drawStartAxis*(state: var uint64, draws: var int32): int32 =
  ## One start-axis direction index per round, drawn from the same stream.
  drawInt(state, draws, 0, int32(DirCount - 1))

proc startPlacement*(axis: int32, roundIndex: int32, bodyIndex: int):
    tuple[x, y, hMilli: int32] =
  ## Where bug `bodyIndex` stands at the first tick of round `roundIndex`, and
  ## which way it faces.
  ##
  ## THE END SWAP: bug 0 takes the drawn axis on EVEN rounds and the opposite
  ## end on ODD ones, so a seat that got the better half of a slightly
  ## asymmetric draw gets the other half next round and no seat owns a side.
  let
    swapped = (roundIndex mod 2) == 1
    mine =
      if (bodyIndex == 0) != swapped: dirIndex(axis)
      else: dirIndex(axis + 16)
    facing = dirIndex(mine + 16)     ## face the ring centre, i.e. each other
  result.x = RingCentreX +
    int32((int64(StartRadius) * int64(dirX(mine))) div int64(Q12))
  result.y = RingCentreY +
    int32((int64(StartRadius) * int64(dirY(mine))) div int64(Q12))
  result.hMilli = facing * 1000'i32

# ---------------------------------------------------------------------------
#  Contacts
# ---------------------------------------------------------------------------

type
  DiscPair* = object
    ## One of the ten disc pairs tested every tick, already resolved to
    ## centres, radii and the relative displacement travelled this tick.
    legA*, legB*: int          ## -1 = the torso disc.
    ax*, ay*, bx*, by*: int32
    ra*, rb*: int32

const SweepScale* = 8'i64
  ## The swept test runs in units of 8 um. Positions square to ~9e13 and the
  ## projection needs one more multiply on top of that, which overflows
  ## `int64` at full micrometre precision; reducing by 8 keeps every
  ## intermediate under 2e16 and costs 8 um of resolution against a 410 000 um
  ## contact threshold (0.002 %). The END-POSITION test — the one the impulse
  ## and penetration split use — stays exact at full precision.

proc segmentClosestSq(px, py, dx, dy: int64): int64 =
  ## Squared distance from the ORIGIN to the segment `p .. p + d`, in reduced
  ## units. Integer throughout: the numerator/denominator comparison replaces
  ## the division a float implementation would do, so nothing rounds away a
  ## contact on one build and keeps it on the other.
  let dd = dx * dx + dy * dy
  if dd == 0:
    return px * px + py * py
  ## t* = -(p.d)/(d.d) clamped to [0, 1]; compared against the NUMERATOR so the
  ## quotient is never formed at full width.
  let num = -(px * dx + py * dy)
  if num <= 0:
    return px * px + py * py
  if num >= dd:
    let
      ex = px + dx
      ey = py + dy
    return ex * ex + ey * ey
  let
    cx = px + (dx * num) div dd
    cy = py + (dy * num) div dd
  cx * cx + cy * cy

proc discsTouch*(pair: DiscPair, relDx, relDy: int64):
    tuple[hit: bool, dist: int32] =
  ## A SWEPT overlap test. A contact counts if the discs overlap at the tick's
  ## END position, or if the segment travelled by their relative displacement
  ## this tick passed within `ra + rb` — otherwise a fast foot tunnels straight
  ## through a torso between two ticks and the shove never happens.
  ##
  ## `dist` is the END-position centre distance, which is what the impulse and
  ## the penetration split use. tests/test_physics.nim asserts the swept test
  ## and the end-position test agree over 50 000 randomised legal states, so
  ## the sweep is a guard, not a behaviour change.
  let
    sum = int64(pair.ra) + int64(pair.rb)
    ex = int64(pair.ax) - int64(pair.bx)
    ey = int64(pair.ay) - int64(pair.by)
    endSq = ex * ex + ey * ey
  result.dist = int32(isqrt(endSq))
  if endSq <= sum * sum:
    result.hit = true
    return
  let
    rx = ex div SweepScale
    ry = ey div SweepScale
    rdx = relDx div SweepScale
    rdy = relDy div SweepScale
    rsum = sum div SweepScale
    closest = segmentClosestSq(rx, ry, -rdx, -rdy)
  result.hit = closest <= rsum * rsum

proc normalIndexBetween*(ax, ay, bx, by: int32): int32 =
  ## The direction index closest to the unit vector from B to A, chosen by
  ## exact integer comparison against the committed table. Coincident centres
  ## fall back to index 0, so a normal always exists.
  let
    dx = int64(ax) - int64(bx)
    dy = int64(ay) - int64(by)
  if dx == 0 and dy == 0:
    return 0
  var
    best = 0'i32
    bestDot = low(int64)
  for d in 0 ..< DirCount:
    ## cos of the angle between (dx,dy) and the table entry, up to the common
    ## positive factor |(dx,dy)| — a dot product is enough to rank them.
    let dot = dx * int64(DirQ12[d].x) + dy * int64(DirQ12[d].y)
    if dot > bestDot:
      bestDot = dot
      best = int32(d)
  best

proc crossQ12*(rx, ry, fx, fy: int32): int64 =
  ## The z component of `r x f`, in `int64`. Used for contact torque: an
  ## off-centre hit SPINS you, and spin erodes your own stability.
  int64(rx) * int64(fy) - int64(ry) * int64(fx)
