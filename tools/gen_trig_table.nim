## Regenerates the committed `DirQ12` table in src/bodies/trig.nim.
##
##   nim c -d:release -r tools/gen_trig_table.nim
##
## Entry `d` is the VIEW bearing 11.25 deg * d expressed in SIM (y-down)
## components: (round(4096*cos), round(-4096*sin)). The table is CHECKED IN
## rather than computed at startup because it is the sim's only trigonometry and
## `math.cos` is exactly what the hashed modules may not call;
## tests/test_determinism.nim re-derives every entry from it here instead.
import std/[math, strformat]

when isMainModule:
  echo "  DirQ12*: array[DirCount, tuple[x, y: int32]] = ["
  for d in 0 ..< 32:
    let
      angle = 11.25 * float(d) * PI / 180.0
      x = int32(round(4096.0 * cos(angle)))
      y = int32(round(-4096.0 * sin(angle)))
      comma = if d == 31: "" else: ","
    echo &"    ({x:>6}'i32, {y:>6}'i32){comma}"
  echo "  ]"
