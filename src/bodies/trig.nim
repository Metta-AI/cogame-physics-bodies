## The sim's ONLY trigonometry: a committed 32-entry Q12 unit-vector table and
## an integer square root. No `sin`, `cos`, `arctan2`, `sqrt` or `float`
## appears in this file or in any other hashed module — that is what makes the
## native amd64 server and the emscripten/wasm32 replay viewer agree bit for
## bit rather than depending on two builds of libm agreeing.
##
## `DirQ12[d]` is the VIEW bearing `11.25 deg * d` (0 = east/right, counter-
## clockwise) expressed in SIM components, i.e. y already negated for the
## y-down screen convention, so no call site ever negates anything.
## Generated once by tools/gen_trig_table.nim and checked in;
## tests/test_determinism.nim re-derives every entry from math.cos/math.sin.

const
  DirCount* = 32
  Q12* = 4096'i32

  DirQ12*: array[DirCount, tuple[x, y: int32]] = [
    (  4096'i32,      0'i32),
    (  4017'i32,   -799'i32),
    (  3784'i32,  -1567'i32),
    (  3406'i32,  -2276'i32),
    (  2896'i32,  -2896'i32),
    (  2276'i32,  -3406'i32),
    (  1567'i32,  -3784'i32),
    (   799'i32,  -4017'i32),
    (     0'i32,  -4096'i32),
    (  -799'i32,  -4017'i32),
    ( -1567'i32,  -3784'i32),
    ( -2276'i32,  -3406'i32),
    ( -2896'i32,  -2896'i32),
    ( -3406'i32,  -2276'i32),
    ( -3784'i32,  -1567'i32),
    ( -4017'i32,   -799'i32),
    ( -4096'i32,      0'i32),
    ( -4017'i32,    799'i32),
    ( -3784'i32,   1567'i32),
    ( -3406'i32,   2276'i32),
    ( -2896'i32,   2896'i32),
    ( -2276'i32,   3406'i32),
    ( -1567'i32,   3784'i32),
    (  -799'i32,   4017'i32),
    (     0'i32,   4096'i32),
    (   799'i32,   4017'i32),
    (  1567'i32,   3784'i32),
    (  2276'i32,   3406'i32),
    (  2896'i32,   2896'i32),
    (  3406'i32,   2276'i32),
    (  3784'i32,   1567'i32),
    (  4017'i32,    799'i32)
  ]

proc dirIndex*(d: int32): int32 =
  ## `d` wrapped into `0 .. 31`. Nim's `mod` keeps the sign of the dividend,
  ## so the `+ DirCount` is load-bearing for negative indices.
  ((d mod DirCount) + DirCount) mod DirCount

proc dirX*(d: int32): int32 = DirQ12[dirIndex(d)].x
proc dirY*(d: int32): int32 = DirQ12[dirIndex(d)].y

proc isqrt*(value: int64): int64 =
  ## Integer square root: the largest `r` with `r*r <= value`. Newton's method
  ## from a bit-length seed, then a corrective walk so the result is EXACT for
  ## every input (a Newton iteration alone lands one off on some perfect
  ## squares, and a contact test that is one micrometre out on one build is a
  ## hash mismatch). The only square root in the sim.
  if value <= 0:
    return 0
  if value < 4:
    return 1
  var
    x = value
    shift = 0'i64
  while x > 0:
    x = x shr 2
    shift += 1
  var r = 1'i64 shl shift          ## 2^ceil(bits/2) >= sqrt(value)
  while true:
    let next = (r + value div r) shr 1
    if next >= r:
      break
    r = next
  while r > 0 and r * r > value:
    dec r
  while (r + 1) * (r + 1) <= value:
    inc r
  r

proc distUm*(ax, ay, bx, by: int32): int32 =
  ## Exact integer distance between two micrometre points. The squared span
  ## is computed in `int64` — two 9.6 m coordinates square to ~9.2e13, far
  ## past `int32`.
  let
    dx = int64(ax) - int64(bx)
    dy = int64(ay) - int64(by)
  int32(isqrt(dx * dx + dy * dy))

proc lenUm*(x, y: int32): int32 =
  ## Exact integer length of one micrometre vector.
  let
    fx = int64(x)
    fy = int64(y)
  int32(isqrt(fx * fx + fy * fy))

proc reflectIndex*(d, n: int32): int32 =
  ## Reflection about the outward normal index `n`, as exact index arithmetic.
  dirIndex(2 * n - d + 16)

proc shortestMilli*(delta: int32): int32 =
  ## A milli-index difference wrapped into `(-16000, 16000]`.
  var v = delta mod 32000
  if v > 16000:
    v -= 32000
  elif v <= -16000:
    v += 32000
  v
