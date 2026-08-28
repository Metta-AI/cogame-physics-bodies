## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the chrome sprite id).
##
## Historically each HTML client re-typed these as literals and nothing
## enforced agreement — a retuned `PlaybackSpeeds` would silently desync every
## client. This module renders them ONCE, from the same Nim consts the engine
## runs on; server.nim splices the block into every served page and
## tools/gen_wire_constants.nim emits it for the static wasm bundle.
##
## The global is `window.BODIES_WIRE`. `client/chrome_common.js` is carried over
## from the starter BYTE-FOR-BYTE, so it still reads the starter's own global
## name and falls back to its literals — which are exactly these values, because
## `PlaybackSpeeds` and `TargetFps` are kept verbatim. `broadcast_core.js` reads
## `BODIES_WIRE`.

import std/strutils
import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.BODIES_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",boardW:" & $MapWidth &
  ",boardH:" & $MapHeight &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.BODIES_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
