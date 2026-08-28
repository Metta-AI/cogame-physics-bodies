## 16. EVERY DRAWN STRING FITS ITS FRAME — the BOARD half, measured on the real
## drawing surface.
##
## Nothing in this game draws text through canvas `fillText`
## (`grep -c fillText client/*.js client/*.html replay-viewer/*.js` is 0 in
## every file), so `tools/ci/viewer_smoke.mjs`'s `canvas_text` count is
## structurally 0 and cannot see the one place a model's own words are drawn on
## the board: the reserved speech band, typeset by pixie in Nim
## (`global.textPixels`) and blitted as SPRITE PIXELS through the wire. The DOM
## half is measured in the browser by `tools/ci/renderer_fixture.html`; this
## suite measures the band.
##
## It bakes the band through the REAL frame builders — the same
## `buildSpriteProtocolUpdates` / `buildSpriteProtocolPlayerUpdates` the server
## sends — with a FULL-CAP `say` on BOTH seats at once, at both board scales,
## and then reads the pixels back: the plate must sit wholly inside the board,
## its text must actually be inked, and no ink may reach the plate's padding
## edge, which is what clipping by the image raster looks like.

import std/[strformat, strutils, unicode]
import supersnappy
import bitworld/spriteprotocol
import bodies/[sim, global, intents]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

type Plate = object
  label: string
  w, h: int
  x, y: int
  pixels: seq[uint8]

proc platesOf(packet: seq[uint8]): tuple[plates: seq[Plate],
                                         viewW, viewH: int] =
  ## Every `say …` sprite in one frame, with the placement of the object that
  ## draws it and the board viewport it lands on.
  var
    defs: seq[Plate] = @[]
    ids: seq[int] = @[]
  for message in packet.parseSpritePacket():
    case message.kind
    of spkSprite:
      if message.sprite.label.startsWith("say "):
        defs.add Plate(label: message.sprite.label, w: message.sprite.width,
          h: message.sprite.height, x: low(int), y: low(int),
          pixels: uncompress(message.sprite.compressedPixels))
        ids.add message.sprite.id
    of spkObject:
      for i, id in ids:
        if id == message.objectDef.spriteId:
          defs[i].x = message.objectDef.x
          defs[i].y = message.objectDef.y
    of spkViewport:
      result.viewW = message.viewport.width
      result.viewH = message.viewport.height
    else: discard
  result.plates = defs

proc inkBox(plate: Plate): tuple[count, x0, y0, x1, y1: int] =
  ## The bounding box of the INK. `textPixels` fills the whole plate with the
  ## bug's hull colour at alpha 200 and then draws the glyphs at alpha 255, so
  ## "inked" is exactly "more opaque than the panel".
  result = (0, plate.w, plate.h, -1, -1)
  for y in 0 ..< plate.h:
    for x in 0 ..< plate.w:
      if plate.pixels[(y * plate.w + x) * 4 + 3] > 205'u8:
        inc result.count
        result.x0 = min(result.x0, x)
        result.y0 = min(result.y0, y)
        result.x1 = max(result.x1, x)
        result.y1 = max(result.y1, y)

proc sayFor(kind: string): string =
  ## A full-cap `say`, through the server's own sanitiser. `W` is the widest
  ## printable ASCII glyph and `sanitizeSay` keeps ASCII only, so 48 of them is
  ## the widest string that can ever reach the band.
  case kind
  of "wide": sanitizeSay("W".repeat(MaxSayRunes))
  else: sanitizeSay("walking it to the edge and holding the middle now"[
    0 ..< MaxSayRunes])

proc speakingSim(say: string): SimServer =
  ## A live sim with a full-cap `say` from BOTH seats, installed exactly the
  ## way the server installs one: the intent record the replay carries, pushed
  ## through `pushFeedIntent`, which is what `bubbleLines` reads.
  var cfg = defaultMatchConfig()
  result = initSimServer(cfg)
  result.gameEventLoggingEnabled = false
  result.phase = Playing
  for seat in 0 ..< BodyCount:
    discard result.addPlayer("seat-" & $seat, seat, "")
  for seat in 0 ..< BodyCount:
    var intent = defaultIntent()
    intent.source = isLlm
    intent.say = say
    intent.note = "N".repeat(MaxNoteRunes)
    result.pushFeedIntent(boundedIntentRecord(intent, 24, seat,
      result.bodyOfSeat(seat)))

for kind in ["wide", "prose"]:
  let say = sayFor(kind)
  check say.runeLen == MaxSayRunes,
    &"the {kind} fixture say is {say.runeLen} runes, not the {MaxSayRunes}-" &
    "rune cap — a fixture that quietly shortened its own string would pass " &
    "while testing nothing"
  var sim = speakingSim(say)

  ## Both streams: the seat's board at 1x and the spectator's supersampled
  ## board at `boardRenderScaleFor`. A plate baked at one scale and placed on
  ## the other is exactly how text ends up half-size or off the board.
  var
    seatState = initPlayerViewerState()
    seatNext: PlayerViewerState
    specState = initGlobalViewerState()
    specNext: GlobalViewerState
  let frames = [
    ("seat stream", 1, sim.buildSpriteProtocolPlayerUpdates(0, seatState,
      seatNext)),
    ("spectator", boardRenderScaleFor(MapWidth, MapHeight),
      sim.buildSpriteProtocolUpdates(specState, specNext))]

  for (who, k, packet) in frames:
    let found = platesOf(packet)
    check found.plates.len == BodyCount,
      &"the {who} frame carries {found.plates.len} speech plates for {kind}, " &
      &"want one per bug ({BodyCount})"
    check found.viewW == MapWidth * k and found.viewH == MapHeight * k,
      &"the {who} board viewport is {found.viewW}x{found.viewH}, not " &
      &"{MapWidth * k}x{MapHeight * k}"
    for plate in found.plates:
      ## (a) the fixture's own string is still full length WHERE IT IS DRAWN:
      ## the label carries the exact text the plate was baked from.
      let drawn = plate.label[plate.label.find(": ") + 2 .. ^1]
      check drawn.runeLen == MaxSayRunes,
        &"{who}/{kind}: the plate was baked from {drawn.runeLen} runes, not " &
        &"{MaxSayRunes}"
      check not plate.label.contains("N".repeat(MaxNoteRunes)),
        &"{who}/{kind}: the 160-rune NOTE reached the board — the band is " &
        "sized for the `say` cap only"

      ## (b) the plate is the RESERVED band, at this stream's scale.
      check plate.w == BubbleWidthPx * k and plate.h == BubbleBandHeightPx * k,
        &"{who}/{kind}: the plate is {plate.w}x{plate.h}, not the reserved " &
        &"{BubbleWidthPx * k}x{BubbleBandHeightPx * k}"

      ## (c) the WHOLE plate is inside the board it is placed on. A sprite
      ## placed at a negative coordinate, or past the far edge, is accepted in
      ## silence by every renderer in the chain (cogchemists, 2026-08-24).
      check plate.x >= 0 and plate.y >= 0 and
          plate.x + plate.w <= found.viewW and
          plate.y + plate.h <= found.viewH,
        &"{who}/{kind}: the plate at ({plate.x}, {plate.y}) {plate.w}x" &
        &"{plate.h} is not wholly inside the {found.viewW}x{found.viewH} board"
      check plate.y == BubbleBandTopPx * k,
        &"{who}/{kind}: the plate sits at y {plate.y}, not the reserved " &
        &"band top {BubbleBandTopPx * k} — the band is reserved whether or " &
        "not anything is speaking, so it may not move with the text"

      ## (d) the text was really drawn, and it fits: `textPixels` typesets
      ## inside `(w - 16 * pad, h - 8 * pad)` and draws at `(8 * pad,
      ## 4 * pad)`, so ink outside that inset means pixie ran out of room and
      ## the raster cut the glyphs.
      let
        pad = k
        ink = plate.inkBox()
      check ink.count > 0,
        &"{who}/{kind}: the plate carries NO ink — a full-cap say typeset " &
        "into nothing is invisible to every load signal there is"
      if ink.count > 0:
        check ink.x0 >= 8 * pad - 1 and ink.x1 <= plate.w - 8 * pad,
          &"{who}/{kind}: ink spans x {ink.x0}..{ink.x1} of {plate.w}, " &
          &"outside the {8 * pad}..{plate.w - 8 * pad} text box — the say " &
          "is clipped horizontally"
        check ink.y0 >= 4 * pad - 1 and ink.y1 <= plate.h - 4 * pad,
          &"{who}/{kind}: ink spans y {ink.y0}..{ink.y1} of {plate.h}, " &
          &"outside the {4 * pad}..{plate.h - 4 * pad} text box — the say " &
          "is clipped vertically (it needs more lines than the band reserves)"
      echo &"{who}/{kind} k={k}: plate ({plate.x}, {plate.y}) {plate.w}x" &
        &"{plate.h} on {found.viewW}x{found.viewH}, ink x {ink.x0}..{ink.x1} " &
        &"y {ink.y0}..{ink.y1} ({ink.count} px)"

# --- the band's DWELL: 2.5 s, then the line is gone --------------------
block:
  ## §Readouts 6 draws a line for 2.5 s. The records live in a ring buffer of
  ## `2 * BodyCount`, so before r1 review N14 a remark stayed on the board
  ## until another one replaced it. The plate is placed while the line is
  ## young and gone once it is `BubbleHoldTicks` old — and the reserved band
  ## does not move either way, so nothing on the board jumps.
  let say = sayFor("prose")
  var sim = speakingSim(say)
  sim.tickCount = 24 * max(1, sim.config.turnTicks)      ## the turn boundary
  var freshState = initGlobalViewerState()
  var freshNext: GlobalViewerState
  let fresh = platesOf(sim.buildSpriteProtocolUpdates(freshState, freshNext))
  check fresh.plates.len == BodyCount,
    &"a line spoken this turn placed {fresh.plates.len} plates, want " &
    $BodyCount

  sim.tickCount += BubbleHoldTicks + 1
  var staleState = initGlobalViewerState()
  var staleNext: GlobalViewerState
  let stale = platesOf(sim.buildSpriteProtocolUpdates(staleState, staleNext))
  check stale.plates.len == 0,
    &"a line {BubbleHoldTicks + 1} ticks old still placed " &
    &"{stale.plates.len} plates — it must be drawn for " &
    &"{BubbleHoldTicks} ticks (2.5 s) and then go away"
  check stale.viewW == fresh.viewW and stale.viewH == fresh.viewH,
    "the board viewport moved when the line expired"

if failures > 0:
  quit("test_text_bounds: " & $failures & " failure(s)", 1)
echo "test_text_bounds: ok"
