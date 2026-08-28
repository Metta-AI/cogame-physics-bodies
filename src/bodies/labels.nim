## View-space conversion and HUD/label composition.
##
## VIEW COORDINATES are the only coordinates a policy or the chrome ever sees:
## metres with the origin at the arena's BOTTOM-LEFT corner, x right, y UP, and
## bearings in degrees counter-clockwise from east (0 = right, 90 = up). The sim
## itself is micrometres, y-down (ctf's screen convention), so every crossing
## of that boundary goes through this file.
##
## Floats are legal here: nothing in this module enters `gameHash` — it feeds
## the observation JSON, the broadcast chrome and the sprite labels, exactly
## ctf's split between the hashed sim and the rendered/reported view.

import std/strutils
import sim_types, trig, ring, body

proc viewX*(xUm: int32): float =
  float(xUm) / 1_000_000.0

proc viewY*(yUm: int32): float =
  float(int64(ArenaH) - int64(yUm)) / 1_000_000.0

proc roundTo*(value: float, places: int): float =
  var scale = 1.0
  for _ in 0 ..< places:
    scale *= 10.0
  let scaled = value * scale
  let rounded =
    if scaled >= 0.0: float(int64(scaled + 0.5))
    else: -float(int64(-scaled + 0.5))
  rounded / scale

proc round2*(value: float): float = roundTo(value, 2)
proc round3*(value: float): float = roundTo(value, 3)

proc metres*(um: int32): float = round2(float(um) / 1_000_000.0)

proc bearingDegFor*(dirIdx: int32): float =
  ## The VIEW bearing of a direction index, in degrees.
  float(int(dirIndex(dirIdx))) * 11.25

proc headingDeg*(b: Body): float =
  round2(float(b.hMilli) * 11.25 / 1000.0)

proc spinDps*(b: Body): float =
  ## Yaw rate in degrees per second in VIEW orientation. The sim's positive
  ## omega advances the direction index, which is counter-clockwise in view
  ## space, so no sign flip is needed here.
  round2(float(b.omegaMilli) * 11.25 * float(TargetFps) / 1000.0)

proc speedMs*(b: Body): float =
  round2(float(b.speedUm()) * float(TargetFps) / 1_000_000.0)

proc velMs*(component: int32): float =
  round2(float(component) * float(TargetFps) / 1_000_000.0)

proc tiltPct*(b: Body): int =
  int((int64(b.tipMilli) * 100) div int64(TipDown))

proc bearingFromTo*(ax, ay, bx, by: int32): float =
  ## The view bearing from A to B, quantised to the committed direction table,
  ## so no `arctan2` is needed anywhere in the observation path.
  bearingDegFor(normalIndexBetween(bx, by, ax, ay))

proc formatMetres*(um: int32): string =
  ## "2.31" — the ring-radius caption's number, formatted from integers.
  let
    whole = int64(um) div 1_000_000
    frac = (int64(um) mod 1_000_000 + 5_000) div 10_000
  $whole & "." & align($frac, 2, '0')

proc formatScore*(micro: int64): string =
  ## A micro-point score as a signed 3-decimal string ("+2.750").
  let
    sign = if micro < 0: "-" else: "+"
    mag = abs(micro)
    whole = mag div 1_000_000
    frac = (mag mod 1_000_000) div 1_000
  sign & $whole & "." & align($frac, 3, '0')

# --- sprite labels ---------------------------------------------------------
# Every sprite the board emits carries a non-empty, machine-readable label:
# the inspector and any label-scanning reader key off it, and an empty label
# silently re-sends forever (ctf's addSpriteChanged asserts on it).

const
  LabelRing* = "ring"
  LabelRingArc* = "ring rim"
  LabelBoards* = "boards"
  LabelDust* = "dust"
  LabelBurst* = "impulse burst"
  LabelOutStamp* = "ring out stamp"
  LabelLiftChip* = "lift chip"

proc labelBug*(bodyIndex: int): string =
  "bug " & alias(bodyIndex)

proc labelTorso*(bodyIndex: int, posture: Posture, down: bool): string =
  "torso " & alias(bodyIndex) & " " & $posture & (if down: " down" else: "")

proc labelLeg*(bodyIndex, leg: int, grounded: bool, load: int32): string =
  "leg " & alias(bodyIndex) & " " & $leg &
    (if grounded: " floor" else: " air") & " load " & $load

proc labelTilt*(bodyIndex: int, pct: int): string =
  "tilt " & alias(bodyIndex) & " " & $pct & "%"

proc labelPips*(bodyIndex: int, rounds: int): string =
  "rounds " & alias(bodyIndex) & " " & $rounds

proc labelSay*(bodyIndex: int, text: string): string =
  "say " & alias(bodyIndex) & " " & text

proc labelStatus*(text: string): string =
  "status " & text
