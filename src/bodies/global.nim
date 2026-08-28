## The board renderer: top-down sprite composition for THE RING.
##
## Replaces ctf's `global.nim` fog of war, vision cones, first-person raycast,
## killfeed art and item sprites with the ring itself: sanded clay, painted rim,
## the LIVE SHRINKING rim drawn as a bright arc that visibly contracts, two bug
## hulls with four INDIVIDUALLY POSITIONED legs, dust at loaded feet, tilt
## gauges, impulse bursts and the ring-out stamp. Perfect information both
## sides: the ring is lit and both bodies are in it.
##
## KEPT VERBATIM from ctf: `boardRenderScaleFor`, `RenderScale`,
## `MaxSupersampledMapPixels`, `predictedViewerRenderBytes`,
## `WasmViewerBudgetBytes`, `shoutBubbleZoomFor`, `BroadcastChromeSpriteId`,
## `chunkSpritePacket`, `stripSpritePixels` and `dedupObjectPlacements`.
##
## Floats are legal here: nothing in this module enters `gameHash`.

import std/[json, math, os, strutils, tables]
import pixie
import bitworld/spriteprotocol
import sim, labels

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the broadcast chrome
    ## JSON (scorebug / clock / scrubber / roster / events). The chrome rides
    ## the SAME binary sprite channel the board rides, because that is the only
    ## channel that survives a hosted replay — an opt-in TextMessage channel
    ## froze the HUD at its DOM defaults while the board played fine.

  MapLayerId* = 0
  MapLayerType* = 0
  ZoomableLayerFlag* = SpriteLayerZoomableFlag

  ## Map bands. `broadcast_core.js` caches static bands only for object ids
  ## 40..99 on layer 0 at z = low(int16), so the pool and the z are load-bearing
  ## (a band outside the window silently disables the cache for the whole board
  ## and turns every frame into a full re-blit).
  MapBandSpriteBase* = 30
  MapBandObjectBase* = 40
  MapBandMaxCount* = 60
  MapBandHeight* = 192

  RimBlobCount = 96
  RimSpriteBase = 200          ## +0 chalk, +1 danger
  RimObjectBase = 1000
  TorsoSpriteBase = 300        ## + body*8 + posture*2 + down
  TorsoObjectBase = 1200
  NoseSpriteBase = 330         ## + body
  NoseObjectBase = 1204
  FootSpriteBase = 340         ## + body*4 + grounded*2 + loaded
  FootObjectBase = 1210
  ShinSpriteBase = 356         ## + body
  ShinObjectBase = 1230        ## + body*8 + leg*2 + segment
  DustSpriteBase = 360         ## + stage(0..2)
  DustObjectBase = 1250        ## + body*4 + leg
  TiltSpriteBase = 380         ## + body*11 + bucket
  TiltObjectBase = 1270
  BurstSpriteBase = 420        ## + stage(0..3)
  BurstObjectId = 1280
  LiftChipSpriteId = 430
  LiftChipObjectId = 1281
  OutStampSpriteBase = 440     ## + body
  OutStampObjectBase = 1282
  BubbleSpriteBase = 460       ## + body
  BubbleObjectBase = 1290

  ## The reserved speech band across the TOP of the arena, in VIEW metres
  ## Y in [5.70, 6.30] — i.e. sim y 100 000 .. 700 000 um, board rows 20..140.
  ## Bubbles are NEVER positioned relative to a bug: text laid out relative to
  ## a body near the top of the arena draws at a negative coordinate and a
  ## canvas accepts it silently (cogchemists, 2026-08-24).
  ## Exported so tests/test_text_bounds.nim can measure the baked band against
  ## the reservation it is sized from rather than against a copy of it.
  BubbleBandTopPx* = 20
  BubbleBandHeightPx* = 120
  BubbleWidthPx* = 880
  BubbleFontPx* = 26.0

  ShoutZoomBaseW = 1235.0
  ShoutZoomBaseH = 659.0

## --- Board render scale (spectator/replay supersampling), kept from ctf ----
const RenderScale* {.intdefine.} = 2
const MaxSupersampledMapPixels* {.intdefine.} = 8_000_000
const WasmViewerBudgetBytes* = 1_600_000_000

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## The spectator supersample factor for a board of the given logical size:
  ## RenderScale, unless the board is so large that supersampled bakes would
  ## exhaust the wasm32 replay viewer.
  if mapWidth * mapHeight > MaxSupersampledMapPixels: 1
  else: RenderScale

proc shoutBubbleZoomFor*(mapWidth, mapHeight: int): int =
  ## How many times its base footprint a BOARD speech bubble draws at on this
  ## map, so it keeps the on-screen size it has on the standard field.
  max(1, int(round(max(mapWidth.float / ShoutZoomBaseW,
                       mapHeight.float / ShoutZoomBaseH))))

proc predictedViewerRenderBytes*(mapWidth, mapHeight: int): int64 =
  ## Engineering estimate of the replay viewer's peak working set for one
  ## board, at the scale `boardRenderScaleFor` picks for it. 1920 x 1280 at
  ## k = 2 predicts ~216 MB against the 1.6 GB budget — 7x headroom.
  let
    px = int64(mapWidth) * int64(mapHeight)
    k = int64(boardRenderScaleFor(mapWidth, mapHeight))
  px * 4 * (4 * k * k + 6)

type
  SpriteDefinition = ref object
    spriteId: int
    width: int
    height: int
    label: string

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    mouseX*: int
    mouseY*: int
    mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool          ## the full lead series has been sent already.
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]
    ## Last placement payload sent per object id, flat-indexed by the u16 id
    ## (byte 11 = present flag). The protocol is retained-mode, so an unchanged
    ## placement need never be re-sent.
    sentPlacements*: seq[array[12, uint8]]
    spriteDefs: seq[SpriteDefinition]

var boardScale = 1
  ## Current emission scale. 1 for every player stream; RenderScale inside the
  ## global broadcast/replay board section. Module state (not a parameter)
  ## because the emission helpers are shared between the two builders.

proc initGlobalViewerState*(): GlobalViewerState =
  result.mouseLayer = MapLayerId
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc initPlayerViewerState*(): PlayerViewerState =
  new(result)

# ---------------------------------------------------------------------------
#  Viewer input
# ---------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands (`s:<tick>`) are intercepted BEFORE the legacy char-by-char
  ## transport path, so a multi-digit tick is never mangled into speed
  ## keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = if item.hasLayer: item.layer else: MapLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientInputMessage, SpriteClientReadyMessage,
        SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(state: PlayerViewerState, message: string,
                               chatText: var string) =
  ## Applies sprite player protocol messages. PLAYER SOCKETS CONTRIBUTE NO
  ## INPUT: every command byte comes from the control layer, so an input mask
  ## arriving here is discarded outright (recording it would write a second,
  ## conflicting action row per tick).
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage, SpriteClientMouseMoveMessage,
        SpriteClientMouseButtonMessage, SpriteClientReadyMessage,
        SpriteClientDebugSpriteMessage:
      discard

# ---------------------------------------------------------------------------
#  Packet plumbing (kept from ctf)
# ---------------------------------------------------------------------------

proc spriteDefinitionIndex(defs: openArray[SpriteDefinition],
                           spriteId: int): int =
  for i in 0 ..< defs.len:
    if defs[i].spriteId == spriteId:
      return i
  -1

proc spriteNeeded(defs: openArray[SpriteDefinition], spriteId, width,
                  height: int, label: string): bool =
  ## Whether this viewer still needs a definition for `spriteId`. Callers whose
  ## pixels are EXPENSIVE to bake (the text plates) ask first: passing freshly
  ## baked pixels as an argument would rasterise them every tick and only then
  ## discover the definition had not changed.
  let index = defs.spriteDefinitionIndex(spriteId)
  index < 0 or defs[index].width != width or defs[index].height != height or
    defs[index].label != label

proc addSpriteChanged(packet: var seq[uint8], defs: var seq[SpriteDefinition],
                      spriteId, width, height: int, pixels: openArray[uint8],
                      label: string) =
  ## Appends a sprite definition when its metadata changed. Every sprite MUST
  ## carry a non-empty label — readers key off it, and an empty label silently
  ## re-sends forever.
  doAssert label.len > 0, "sprite " & $spriteId & " needs a non-empty label"
  doAssert spriteId >= 0 and spriteId <= 65535,
    "sprite id " & $spriteId & " (" & label & ") crosses the u16 wire ceiling"
  let index = defs.spriteDefinitionIndex(spriteId)
  if index >= 0:
    if defs[index].width == width and defs[index].height == height and
        defs[index].label == label:
      return
    defs[index].width = width
    defs[index].height = height
    defs[index].label = label
  else:
    defs.add SpriteDefinition(spriteId: spriteId, width: width,
      height: height, label: label)
  packet.addSprite(spriteId, width, height, pixels, label)

proc addBoardObject(packet: var seq[uint8],
                    objectId, x, y, z, layerId, spriteId: int) =
  ## `addObject` for renderer emissions: placements on the zoomable board layer
  ## scale by `boardScale`; z is ordering-only and never scales.
  if layerId == MapLayerId:
    packet.addObject(objectId, x * boardScale, y * boardScale, z, layerId,
      spriteId)
  else:
    packet.addObject(objectId, x, y, z, layerId, spriteId)

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into WS-frame-sized chunks at MESSAGE
  ## boundaries. The hosted replay closes any frame over 1 MiB (1009), and the
  ## client accumulates state across binary messages, so N chunks are
  ## equivalent to one packet as long as no frame is cut mid-message.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let msgStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let clen = packet.readU32(offset + 6)
      offset += 10 + clen
      let llen = packet.readU16(offset)
      offset += 2 + llen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      break
    if offset - chunkStart > maxBytes and msgStart > chunkStart:
      result.add(packet[chunkStart ..< msgStart])
      chunkStart = msgStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc stripSpritePixels*(packet: seq[uint8]): seq[uint8] =
  ## Rewrites one packet for a Sprites Off (0x87) client: sprite definitions
  ## keep id, dimensions and label but ship a zero-length pixel payload.
  result = newSeqOfCap[uint8](packet.len)
  var offset = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let compressedLen = packet.readU32(offset + 6)
      let labelStart = offset + 10 + compressedLen
      let labelLen = packet.readU16(labelStart)
      let messageEnd = labelStart + 2 + labelLen
      for i in messageStart ..< offset + 6:
        result.add(packet[i])
      result.addU32(0)
      for i in labelStart ..< messageEnd:
        result.add(packet[i])
      offset = messageEnd
    of 0x02, 0x03, 0x04, 0x05, 0x06:
      offset += (
        case messageType
        of 0x02: 11
        of 0x03: 2
        of 0x05: 5
        of 0x06: 3
        else: 0)
      for i in messageStart ..< offset:
        result.add(packet[i])
    else:
      for i in messageStart ..< packet.len:
        result.add(packet[i])
      break

proc dedupObjectPlacements*(packet: seq[uint8],
                            sentPlacements: var seq[array[12, uint8]]): seq[uint8] =
  ## Drops Define Object messages whose full payload matches what this viewer
  ## was already sent. The protocol is retained-mode, so re-sending an
  ## identical placement is pure wire noise.
  result = newSeqOfCap[uint8](packet.len)
  if sentPlacements.len == 0:
    sentPlacements.setLen(65536)
  var
    offset = 0
    keepStart = 0
  template flushKept(upTo: int) =
    if upTo > keepStart:
      let start = result.len
      result.setLen(start + upTo - keepStart)
      copyMem(addr result[start], unsafeAddr packet[keepStart],
        upTo - keepStart)
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      offset += 10 + packet.readU32(offset + 6)
      offset += 2 + packet.readU16(offset)
    of 0x02:
      var payload: array[12, uint8]
      copyMem(addr payload[0], unsafeAddr packet[offset], 11)
      payload[11] = 1
      offset += 11
      let objectId = int(payload[0]) or (int(payload[1]) shl 8)
      if sentPlacements[objectId] == payload:
        flushKept(messageStart)
        keepStart = offset
      else:
        sentPlacements[objectId] = payload
    of 0x03:
      sentPlacements[packet.readU16(offset)][11] = 0
      offset += 2
    of 0x04:
      zeroMem(addr sentPlacements[0], sentPlacements.len * 12)
    of 0x05, 0x06:
      offset += (if messageType == 0x05: 5 else: 3)
    else:
      offset = packet.len
  flushKept(packet.len)

# ---------------------------------------------------------------------------
#  The art bakes (pixie, once at startup)
# ---------------------------------------------------------------------------
# Real art, and mostly baked from what the repo already ships: the clay floor,
# the rim paint, the dark boards outside, the two bug hulls and their leg
# segments, the dust puffs, the impulse bursts, the tilt arcs and the vignette
# are baked once with pixie from `data/arena_floor.png` and
# `client/art/walls/wall_h.jpg` / `wall_v.jpg`, with `data/font.ttf` for every
# label. No solid-colour placeholders, no TODO assets, no downloaded art.

proc gameDir(): string =
  when defined(emscripten):
    "/"
  else:
    getCurrentDir()

proc assetPath(relative: string): string =
  ## Assets resolve against the working directory (the Dockerfile chdir's to
  ## /workspace/bodies and copies `data/` and `client/` beside the binary), and
  ## against the emscripten preload mount in the wasm bundle.
  for candidate in [gameDir() / relative, relative, ".." / relative]:
    if fileExists(candidate):
      return candidate
  gameDir() / relative

type
  BugPalette = object
    hull, rim, leg, glow: ColorRGBX

const
  ## Amber BUG-1 and teal BUG-2 — the two chrome plate colours.
  BugPalettes: array[BodyCount, BugPalette] = [
    BugPalette(
      hull: ColorRGBX(r: 128, g: 78, b: 26, a: 255),
      rim: ColorRGBX(r: 232, g: 163, b: 61, a: 255),
      leg: ColorRGBX(r: 198, g: 132, b: 48, a: 255),
      glow: ColorRGBX(r: 255, g: 224, b: 150, a: 255)),
    BugPalette(
      hull: ColorRGBX(r: 24, g: 78, b: 96, a: 255),
      rim: ColorRGBX(r: 63, g: 172, b: 196, a: 255),
      leg: ColorRGBX(r: 48, g: 140, b: 164, a: 255),
      glow: ColorRGBX(r: 168, g: 236, b: 250, a: 255))
  ]
  ClayInk = ColorRGBX(r: 214, g: 176, b: 126, a: 255)
  ChalkInk = ColorRGBX(r: 242, g: 232, b: 216, a: 255)
  DangerInk = ColorRGBX(r: 224, g: 82, b: 58, a: 255)
  BoardInk = ColorRGBX(r: 34, g: 26, b: 20, a: 255)

var
  clayPlate: Image
  boardsPlate: Image
  boardTypefaceCache: Typeface
  mapBandsCache: seq[uint8]
  mapBandsDefs: seq[SpriteDefinition]
  spriteCache = initTable[(int, int), tuple[w, h: int, pixels: seq[uint8]]]()
    ## Keyed by (spriteId, boardScale): the SAME sprite id is baked at 1x for
    ## the player streams and at RenderScale for the spectator board, and a
    ## scale-blind cache would hand one scale's pixels to the other.

proc boardTypeface(): Typeface =
  if boardTypefaceCache.isNil:
    boardTypefaceCache = readTypeface(assetPath("data/font.ttf"))
  boardTypefaceCache

proc loadPlate(path: string, fallback: ColorRGBX): Image =
  try:
    result = readImage(assetPath(path))
  except CatchableError:
    result = newImage(64, 64)
    result.fill(fallback)

proc clay(): Image =
  if clayPlate.isNil:
    clayPlate = loadPlate("data/arena_floor.png", ClayInk)
  clayPlate

proc boards(): Image =
  if boardsPlate.isNil:
    boardsPlate = loadPlate("client/art/walls/wall_v.jpg", BoardInk)
  boardsPlate

proc samplePlate(plate: Image, x, y: int): ColorRGBX =
  plate.unsafe[x mod plate.width, y mod plate.height]

proc putPixel(pixels: var seq[uint8], index: int, color: ColorRGBX, alpha: int) =
  let a = clamp(alpha, 0, 255)
  if a == 0:
    return
  let offset = index * 4
  if pixels[offset + 3] == 0 or a == 255:
    pixels[offset] = color.r
    pixels[offset + 1] = color.g
    pixels[offset + 2] = color.b
    pixels[offset + 3] = uint8(a)
    return
  let
    src = a.float / 255.0
    dst = pixels[offset + 3].float / 255.0
    outA = src + dst * (1.0 - src)
  if outA <= 0.0:
    return
  pixels[offset] = uint8((color.r.float * src + pixels[offset].float * dst *
    (1.0 - src)) / outA)
  pixels[offset + 1] = uint8((color.g.float * src +
    pixels[offset + 1].float * dst * (1.0 - src)) / outA)
  pixels[offset + 2] = uint8((color.b.float * src +
    pixels[offset + 2].float * dst * (1.0 - src)) / outA)
  pixels[offset + 3] = uint8(outA * 255.0)

proc fillDisc(pixels: var seq[uint8], w, h: int, cx, cy, r: float,
              color: ColorRGBX, alpha = 255) =
  ## An anti-aliased filled disc, in the sprite's own pixel space.
  let
    x0 = max(0, int(cx - r - 1.0))
    x1 = min(w - 1, int(cx + r + 1.0))
    y0 = max(0, int(cy - r - 1.0))
    y1 = min(h - 1, int(cy + r + 1.0))
  for y in y0 .. y1:
    for x in x0 .. x1:
      let
        dx = float(x) + 0.5 - cx
        dy = float(y) + 0.5 - cy
        d = sqrt(dx * dx + dy * dy)
      if d <= r - 0.5:
        pixels.putPixel(y * w + x, color, alpha)
      elif d < r + 0.5:
        pixels.putPixel(y * w + x, color, int(float(alpha) * (r + 0.5 - d)))

proc strokeRing(pixels: var seq[uint8], w, h: int, cx, cy, r, thickness: float,
                color: ColorRGBX, alpha = 255) =
  let
    inner = r - thickness / 2.0
    outer = r + thickness / 2.0
    x0 = max(0, int(cx - outer - 1.0))
    x1 = min(w - 1, int(cx + outer + 1.0))
    y0 = max(0, int(cy - outer - 1.0))
    y1 = min(h - 1, int(cy + outer + 1.0))
  for y in y0 .. y1:
    for x in x0 .. x1:
      let
        dx = float(x) + 0.5 - cx
        dy = float(y) + 0.5 - cy
        d = sqrt(dx * dx + dy * dy)
      if d >= inner and d <= outer:
        pixels.putPixel(y * w + x, color, alpha)

proc newRgba(w, h: int): seq[uint8] = newSeq[uint8](w * h * 4)

proc textPixels(text: string, w, h: int, size: float, color: ColorRGBX,
                bg: ColorRGBX, bgAlpha: int): seq[uint8] =
  ## A text plate baked with `data/font.ttf` through pixie, returned as straight
  ## RGBA for the wire. `w`, `h` and `size` arrive already multiplied by
  ## `boardScale`; the padding scales with them.
  let pad = float32(boardScale)
  var image = newImage(w, h)
  image.fill(rgbx(0, 0, 0, 0))
  if bgAlpha > 0:
    let panel = newImage(w, h)
    panel.fill(rgbx(bg.r, bg.g, bg.b, uint8(bgAlpha)))
    image.draw(panel)
  var font = newFont(boardTypeface())
  font.size = size
  font.paint = rgbx(color.r, color.g, color.b, 255)
  let arrangement = typeset(@[newSpan(text, font)],
    bounds = vec2(float32(w) - 16.0 * pad, float32(h) - 8.0 * pad))
  image.fillText(arrangement, translate(vec2(8.0 * pad, 4.0 * pad)))
  result = newRgba(w, h)
  let data = image.data
  for i in 0 ..< w * h:
    let px = data[i]
    ## pixie stores premultiplied RGBX; the wire wants straight RGBA.
    if px.a == 0:
      continue
    result[i * 4] = uint8(int(px.r) * 255 div int(px.a))
    result[i * 4 + 1] = uint8(int(px.g) * 255 div int(px.a))
    result[i * 4 + 2] = uint8(int(px.b) * 255 div int(px.a))
    result[i * 4 + 3] = px.a

proc bakeMap(k: int): seq[uint8] =
  ## The static plate: sanded clay inside the round-start rim, painted rim
  ## paint on it, dark boards outside, and a soft vignette. The LIVE rim is a
  ## separate contracting arc (see `addRimArc`) so this bakes exactly once.
  let
    w = MapWidth * k
    h = MapHeight * k
    cx = float(RingCentreX) / float(UmPerPixel) * float(k)
    cy = float(RingCentreY) / float(UmPerPixel) * float(k)
    r0 = float(RingRadius0) / float(UmPerPixel) * float(k)
    clayImg = clay()
    boardsImg = boards()
  result = newRgba(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        dx = float(x) + 0.5 - cx
        dy = float(y) + 0.5 - cy
        d = sqrt(dx * dx + dy * dy)
        index = y * w + x
      if d <= r0 + 2.0:
        var px = samplePlate(clayImg, x div k, y div k)
        ## Warm the plate toward clay and let the centre read brighter, so the
        ## middle of the dohyo is visibly the place to be.
        let lift = 1.06 - 0.18 * (d / max(1.0, r0))
        px.r = uint8(clamp(int(float(px.r) * lift), 0, 255))
        px.g = uint8(clamp(int(float(px.g) * lift * 0.98), 0, 255))
        px.b = uint8(clamp(int(float(px.b) * lift * 0.9), 0, 255))
        result[index * 4] = px.r
        result[index * 4 + 1] = px.g
        result[index * 4 + 2] = px.b
        result[index * 4 + 3] = 255
      else:
        var px = samplePlate(boardsImg, x div k, y div k)
        result[index * 4] = uint8(int(px.r) * 38 div 100)
        result[index * 4 + 1] = uint8(int(px.g) * 34 div 100)
        result[index * 4 + 2] = uint8(int(px.b) * 30 div 100)
        result[index * 4 + 3] = 255
  ## The painted rim at the ROUND-START radius: the faint ghost the live arc
  ## contracts away from, so a reader sees how much ring has already gone.
  strokeRing(result, w, h, cx, cy, r0, 3.0 * float(k), ChalkInk, 150)
  strokeRing(result, w, h, cx, cy, r0 - 2.0 * float(k), 1.0 * float(k),
    BoardInk, 60)
  ## Vignette: the boards fall away at the frame edge.
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        fx = min(float(x), float(w - 1 - x)) / float(w)
        fy = min(float(y), float(h - 1 - y)) / float(h)
        edge = min(fx, fy)
      if edge < 0.06:
        let shade = 1.0 - 0.55 * (1.0 - edge / 0.06)
        let index = (y * w + x) * 4
        result[index] = uint8(float(result[index]) * shade)
        result[index + 1] = uint8(float(result[index + 1]) * shade)
        result[index + 2] = uint8(float(result[index + 2]) * shade)

proc bakeTorso(bodyIndex, posture: int, down: bool): tuple[w, h: int,
    pixels: seq[uint8]] =
  ## The bug hull. Posture reads from the LEGS (they are drawn at their actual
  ## computed foot positions), so the hull carries the identity colour, the
  ## posture ring width and, when it is Down, a folded prone plate.
  ##
  ## EVERY board bake multiplies its pixel geometry by `boardScale`, because
  ## `addBoardObject` multiplies its PLACEMENTS by `boardScale` and the map
  ## plate is baked at `MapWidth * boardScale`. A sprite baked at 1x on a 2x
  ## layer draws at HALF its physical size — a 0.30 m bug hull reading as
  ## 0.15 m, with contact happening across a visible gap.
  let
    k = boardScale
    size = (int(2 * TorsoRadius div UmPerPixel) + 8) * k
    pal = BugPalettes[bodyIndex]
    c = float(size) / 2.0
    r = float(TorsoRadius div UmPerPixel) * float(k)
  result.w = size
  result.h = size
  result.pixels = newRgba(size, size)
  if down:
    ## Prone: a flattened, dimmed plate with a countdown pip ring.
    fillDisc(result.pixels, size, size, c, c, r * 0.86, pal.hull, 210)
    strokeRing(result.pixels, size, size, c, c, r * 0.86, 3.0 * float(k),
      pal.rim, 140)
    strokeRing(result.pixels, size, size, c, c, r * 0.5, 2.0 * float(k),
      DangerInk, 220)
    return
  fillDisc(result.pixels, size, size, c, c, r, pal.hull, 255)
  strokeRing(result.pixels, size, size, c, c, r - float(k),
    float(k) * (case posture
     of 0: 7.0      ## low  — a wide, heavy rim
     of 1: 5.0
     of 2: 3.0      ## high — a thin, tall rim
     else: 6.0), pal.rim, 255)
  ## A darker core so the hull reads as a body, not a token.
  fillDisc(result.pixels, size, size, c, c, r * 0.55, pal.hull, 255)
  fillDisc(result.pixels, size, size, c, c, r * 0.30, pal.glow, 90)

proc bakeNose(bodyIndex: int): tuple[w, h: int, pixels: seq[uint8]] =
  ## The heading marker: a bright wedge placed AHEAD of the hull, so facing is
  ## legible without baking 32 rotations of the torso.
  let
    k = boardScale
    size = 26 * k
    pal = BugPalettes[bodyIndex]
  result.w = size
  result.h = size
  result.pixels = newRgba(size, size)
  fillDisc(result.pixels, size, size, float(size) / 2.0, float(size) / 2.0,
    9.0 * float(k), pal.glow, 235)
  fillDisc(result.pixels, size, size, float(size) / 2.0, float(size) / 2.0,
    4.0 * float(k), ChalkInk, 255)

proc bakeFoot(bodyIndex: int, grounded, loaded: bool):
    tuple[w, h: int, pixels: seq[uint8]] =
  ## A foot. A foot over the rim goes DARK and draws no dust — "no floor",
  ## legible without a caption.
  let
    k = boardScale
    size = (int(2 * FootRadius div UmPerPixel) + 8) * k
    pal = BugPalettes[bodyIndex]
    c = float(size) / 2.0
    r = float(FootRadius div UmPerPixel) * float(k)
  result.w = size
  result.h = size
  result.pixels = newRgba(size, size)
  if not grounded:
    fillDisc(result.pixels, size, size, c, c, r, BoardInk, 210)
    strokeRing(result.pixels, size, size, c, c, r, 2.0 * float(k), pal.leg, 110)
    return
  fillDisc(result.pixels, size, size, c, c, r, pal.leg, 255)
  if loaded:
    strokeRing(result.pixels, size, size, c, c, r, 3.0 * float(k), pal.glow, 255)
    fillDisc(result.pixels, size, size, c, c, r * 0.45, pal.glow, 220)

proc bakeShin(bodyIndex: int): tuple[w, h: int, pixels: seq[uint8]] =
  let
    k = boardScale
    size = 12 * k
    pal = BugPalettes[bodyIndex]
  result.w = size
  result.h = size
  result.pixels = newRgba(size, size)
  fillDisc(result.pixels, size, size, float(size) / 2.0, float(size) / 2.0,
    4.5 * float(k), pal.leg, 235)

proc bakeDust(stage: int): tuple[w, h: int, pixels: seq[uint8]] =
  let
    k = boardScale
    size = (34 + stage * 8) * k
  result.w = size
  result.h = size
  result.pixels = newRgba(size, size)
  let
    c = float(size) / 2.0
    edge = c - 2.0 * float(k)
  fillDisc(result.pixels, size, size, c, c, edge, ClayInk, 110 - stage * 30)
  fillDisc(result.pixels, size, size, c, c, edge * 0.6, ClayInk,
    140 - stage * 35)

proc bakeTilt(bodyIndex, bucket: int): tuple[w, h: int, pixels: seq[uint8]] =
  ## The tilt gauge — THE FALL, MADE VISIBLE. An arc over each bug that fills
  ## with tilt, turns amber above 50 % and flashes above 80 %.
  let
    k = boardScale
    w = 96 * k
    h = 34 * k
    pal = BugPalettes[bodyIndex]
    pct = bucket * 10
  result.w = w
  result.h = h
  result.pixels = newRgba(w, h)
  let
    cx = float(w) / 2.0
    cy = float(h) - 3.0 * float(k)
    r = 26.0 * float(k)
    ink =
      if pct >= 80: DangerInk
      elif pct >= 50: ColorRGBX(r: 232, g: 163, b: 61, a: 255)
      else: pal.rim
  ## Track.
  for i in 0 ..< 48:
    let a = PI * (1.0 - float(i) / 47.0)
    let
      x = cx + cos(a) * r
      y = cy - sin(a) * r
    fillDisc(result.pixels, w, h, x, y, 2.0 * float(k), ChalkInk, 70)
  ## Fill.
  let lit = (48 * pct) div 100
  for i in 0 ..< lit:
    let a = PI * (1.0 - float(i) / 47.0)
    let
      x = cx + cos(a) * r
      y = cy - sin(a) * r
    fillDisc(result.pixels, w, h, x, y, 3.0 * float(k), ink, 255)

proc bakeBurst(stage: int): tuple[w, h: int, pixels: seq[uint8]] =
  let
    k = boardScale
    size = (60 + stage * 26) * k
  result.w = size
  result.h = size
  result.pixels = newRgba(size, size)
  let
    c = float(size) / 2.0
    edge = c - 4.0 * float(k)
  strokeRing(result.pixels, size, size, c, c, edge, 5.0 * float(k), ChalkInk,
    max(0, 235 - stage * 60))
  strokeRing(result.pixels, size, size, c, c, edge * 0.6, 3.0 * float(k),
    DangerInk, max(0, 200 - stage * 55))

proc bakeRim(danger: bool): tuple[w, h: int, pixels: seq[uint8]] =
  ## One blob of the LIVE rim. Ninety-six of them ride the current radius, so
  ## the ring visibly contracts without ever re-baking a 2 400 px sprite.
  let
    k = boardScale
    size = 16 * k
  result.w = size
  result.h = size
  result.pixels = newRgba(size, size)
  let c = float(size) / 2.0
  fillDisc(result.pixels, size, size, c, c, 6.0 * float(k),
    (if danger: DangerInk else: ChalkInk), 255)
  fillDisc(result.pixels, size, size, c, c, 3.0 * float(k), ChalkInk,
    (if danger: 200 else: 255))

proc bakeLiftChip(): tuple[w, h: int, pixels: seq[uint8]] =
  let k = boardScale
  result.w = 96 * k
  result.h = 40 * k
  result.pixels = textPixels("LIFT", result.w, result.h, 26.0 * float(k),
    ChalkInk, ColorRGBX(r: 40, g: 30, b: 22, a: 255), 190)

proc bakeOutStamp(bodyIndex: int): tuple[w, h: int, pixels: seq[uint8]] =
  let k = boardScale
  result.w = 200 * k
  result.h = 64 * k
  result.pixels = textPixels(alias(bodyIndex) & " OUT", result.w, result.h,
    36.0 * float(k), ChalkInk, DangerInk, 210)

proc cachedSprite(spriteId: int,
                  bake: proc (): tuple[w, h: int, pixels: seq[uint8]] {.closure.}):
    tuple[w, h: int, pixels: seq[uint8]] =
  spriteCache.withValue((spriteId, boardScale), found):
    return found[]
  result = bake()
  spriteCache[(spriteId, boardScale)] = result

proc halfLogical(spritePx: int): int =
  ## Half a baked sprite's extent expressed in LOGICAL board pixels. Placements
  ## are emitted in logical pixels and scaled by `addBoardObject`, while the
  ## bakes above are already in scaled pixels, so a centering offset taken
  ## straight off `art.w` would be doubled.
  spritePx div (2 * boardScale)

proc invalidateBoardMapCaches*() =
  ## Drops every process-wide cache derived from the board's pixels. Needed
  ## when the serve loop hot-switches replays.
  mapBandsCache = @[]
  mapBandsDefs = @[]
  spriteCache.clear()

# ---------------------------------------------------------------------------
#  Emission
# ---------------------------------------------------------------------------

proc pxOf(um: int32): int = int(um) div UmPerPixel

proc addMapBands(defs: var seq[SpriteDefinition], packet: var seq[uint8]) =
  ## Emits the static plate as a stack of horizontal BANDS instead of one giant
  ## sprite: one ~40 MB map sprite would exceed the hosted 1 MiB WS frame cap
  ## outright. Each band is a full-width crop placed at its own y-offset on the
  ## map layer; the client composites them into one seamless image. Bands are
  ## emitted once per viewer and never tracked in `objectIds`, so the per-frame
  ## delete diff leaves them on the client forever.
  block:
    let sentinel = defs.spriteDefinitionIndex(MapBandSpriteBase)
    if sentinel >= 0 and defs[sentinel].width == MapWidth * boardScale:
      return
  if mapBandsCache.len > 0 and mapBandsDefs.len > 0 and
      mapBandsDefs[0].width == MapWidth * boardScale:
    for def in mapBandsDefs:
      let index = defs.spriteDefinitionIndex(def.spriteId)
      if index >= 0: defs[index] = def else: defs.add def
    packet.add mapBandsCache
    return
  let
    k = boardScale
    pixels = bakeMap(k)
    outW = MapWidth * k
    logicalBandH = max(1, MapBandHeight div (k * k))
  var
    encoded: seq[uint8]
    encodedDefs: seq[SpriteDefinition]
    band = 0
    y0 = 0
  while y0 < MapHeight and band < MapBandMaxCount:
    let
      bandH = min(logicalBandH, MapHeight - y0)
      outBandH = bandH * k
      outY0 = y0 * k
    var bandPixels = newSeq[uint8](outW * outBandH * 4)
    copyMem(bandPixels[0].addr, pixels[outY0 * outW * 4].unsafeAddr,
      outW * outBandH * 4)
    encoded.addSpriteChanged(encodedDefs, MapBandSpriteBase + band, outW,
      outBandH, bandPixels, LabelBoards & " band " & $band)
    encoded.addBoardObject(MapBandObjectBase + band, 0, y0, low(int16),
      MapLayerId, MapBandSpriteBase + band)
    inc band
    y0 += bandH
  mapBandsCache = encoded
  mapBandsDefs = encodedDefs
  for def in encodedDefs:
    let index = defs.spriteDefinitionIndex(def.spriteId)
    if index >= 0: defs[index] = def else: defs.add def
  packet.add encoded

proc addSpriteFor(packet: var seq[uint8], defs: var seq[SpriteDefinition],
                  spriteId: int, label: string,
                  bake: proc (): tuple[w, h: int, pixels: seq[uint8]] {.closure.}) =
  let art = cachedSprite(spriteId, bake)
  packet.addSpriteChanged(defs, spriteId, art.w, art.h, art.pixels, label)

proc addRimArc(sim: SimServer, defs: var seq[SpriteDefinition],
               currentIds: var seq[int], packet: var seq[uint8]) =
  ## The live rim: 96 chalk blobs on the CURRENT radius. The arc nearest a bug
  ## lights red once that bug is within 0.45 m of it, which is the ring-out
  ## warning and a first-class readout rather than flavour.
  packet.addSpriteFor(defs, RimSpriteBase, LabelRingArc,
    proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeRim(false))
  packet.addSpriteFor(defs, RimSpriteBase + 1, LabelRingArc & " danger",
    proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeRim(true))
  let radius = float(sim.ringRadiusNow) / float(UmPerPixel)
  for i in 0 ..< RimBlobCount:
    let
      angle = 2.0 * PI * float(i) / float(RimBlobCount)
      x = float(RingCentreX div UmPerPixel) + cos(angle) * radius
      y = float(RingCentreY div UmPerPixel) + sin(angle) * radius
    var danger = false
    for b in 0 ..< BodyCount:
      let body = sim.bodies[b]
      let
        dx = x - float(pxOf(body.px))
        dy = y - float(pxOf(body.py))
      if sqrt(dx * dx + dy * dy) < 450_000.0 / float(UmPerPixel):
        danger = true
    let objectId = RimObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(objectId, int(x) - 8, int(y) - 8, -200, MapLayerId,
      RimSpriteBase + (if danger: 1 else: 0))

proc addBugs(sim: SimServer, defs: var seq[SpriteDefinition],
             currentIds: var seq[int], packet: var seq[uint8]) =
  ## Two bug hulls with four legs drawn at their ACTUAL computed foot
  ## positions, so the reader SEES posture: `low` is a wide stable star, `high`
  ## a tight tall cross, `lift` lopsided forward.
  for b in 0 ..< BodyCount:
    let
      body = sim.bodies[b]
      postureIdx = clamp(int(body.posture()), 0, 3)
      down = body.downTicks > 0
      torsoSprite = TorsoSpriteBase + b * 8 + postureIdx * 2 +
        (if down: 1 else: 0)
      capturedPosture = postureIdx
      capturedDown = down
      capturedBody = b
    packet.addSpriteFor(defs, torsoSprite,
      labelTorso(b, postureOf(int32(postureIdx)), down),
      proc (): tuple[w, h: int, pixels: seq[uint8]] =
        bakeTorso(capturedBody, capturedPosture, capturedDown))
    packet.addSpriteFor(defs, NoseSpriteBase + b, labelBug(b) & " heading",
      proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeNose(capturedBody))

    ## Legs first (under the hull), then the hull, then the nose.
    for leg in 0 ..< LegCount:
      let
        grounded = body.footGrounded[leg] and not down
        loaded = grounded and body.effort() > 0
        footSprite = FootSpriteBase + b * 4 + (if grounded: 2 else: 0) +
          (if loaded: 1 else: 0)
        capturedGrounded = grounded
        capturedLoaded = loaded
      packet.addSpriteFor(defs, footSprite,
        labelLeg(b, leg, grounded, body.effort()),
        proc (): tuple[w, h: int, pixels: seq[uint8]] =
          bakeFoot(capturedBody, capturedGrounded, capturedLoaded))
      packet.addSpriteFor(defs, ShinSpriteBase + b, labelBug(b) & " shin",
        proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeShin(capturedBody))
      let
        fx = pxOf(body.footX[leg])
        fy = pxOf(body.footY[leg])
        tx = pxOf(body.px)
        ty = pxOf(body.py)
        footHalf = (int(2 * FootRadius div UmPerPixel) + 8) div 2
      if not down:
        for segment in 0 ..< 2:
          let
            t = float(segment + 1) / 3.0
            sx = int(float(tx) + (float(fx) - float(tx)) * t)
            sy = int(float(ty) + (float(fy) - float(ty)) * t)
            objectId = ShinObjectBase + b * 8 + leg * 2 + segment
          currentIds.add(objectId)
          packet.addBoardObject(objectId, sx - 6, sy - 6, fy - 2, MapLayerId,
            ShinSpriteBase + b)
      let footObject = FootObjectBase + b * 4 + leg
      currentIds.add(footObject)
      packet.addBoardObject(footObject, fx - footHalf, fy - footHalf, fy - 1,
        MapLayerId, footSprite)
      ## Dust at a loaded, grounded foot. A foot over the rim draws none.
      if loaded:
        let
          stage = (sim.tickCount div 3) mod 3
          dustSprite = DustSpriteBase + stage
          capturedStage = stage
        packet.addSpriteFor(defs, dustSprite, LabelDust & " " & $stage,
          proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeDust(capturedStage))
        let
          art = cachedSprite(dustSprite,
            proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeDust(capturedStage))
          dustObject = DustObjectBase + b * 4 + leg
        currentIds.add(dustObject)
        packet.addBoardObject(dustObject, fx - halfLogical(art.w),
          fy - halfLogical(art.h),
          fy - 3, MapLayerId, dustSprite)

    let
      torsoArt = cachedSprite(torsoSprite,
        proc (): tuple[w, h: int, pixels: seq[uint8]] =
          bakeTorso(capturedBody, capturedPosture, capturedDown))
      torsoObject = TorsoObjectBase + b
    currentIds.add(torsoObject)
    packet.addBoardObject(torsoObject, pxOf(body.px) - halfLogical(torsoArt.w),
      pxOf(body.py) - halfLogical(torsoArt.h), pxOf(body.py) + 2, MapLayerId,
      torsoSprite)

    if not down:
      let
        idx = body.headingDirIndex()
        nx = pxOf(body.px) + int(0.60 * float(TorsoRadius div UmPerPixel) *
          float(dirX(idx)) / float(Q12))
        ny = pxOf(body.py) + int(0.60 * float(TorsoRadius div UmPerPixel) *
          float(dirY(idx)) / float(Q12))
        noseObject = NoseObjectBase + b
      currentIds.add(noseObject)
      packet.addBoardObject(noseObject, nx - 13, ny - 13, pxOf(body.py) + 3,
        MapLayerId, NoseSpriteBase + b)

    ## The tilt gauge, above the hull.
    let
      bucket = clamp(tiltPct(body) div 10, 0, 10)
      tiltSprite = TiltSpriteBase + b * 11 + bucket
      capturedBucket = bucket
    packet.addSpriteFor(defs, tiltSprite, labelTilt(b, bucket * 10),
      proc (): tuple[w, h: int, pixels: seq[uint8]] =
        bakeTilt(capturedBody, capturedBucket))
    let tiltObject = TiltObjectBase + b
    currentIds.add(tiltObject)
    packet.addBoardObject(tiltObject, pxOf(body.px) - 48,
      pxOf(body.py) - halfLogical(torsoArt.h) - 38, pxOf(body.py) + 4, MapLayerId,
      tiltSprite)

proc addContactFx(sim: SimServer, defs: var seq[SpriteDefinition],
                  currentIds: var seq[int], packet: var seq[uint8]) =
  ## An impulse burst at the contact point sized by |j| + shove, and a LIFT
  ## chip whenever a `lift` posture is in contact.
  let age = sim.tickCount - int(sim.lastFx.tick)
  if sim.lastFx.impulseUm <= 0 or age < 0 or age >= 8:
    return
  let
    stage = clamp(age div 2, 0, 3)
    sizeBoost = clamp(int(sim.lastFx.impulseUm) div 40_000, 0, 2)
    spriteId = BurstSpriteBase + clamp(stage + sizeBoost, 0, 3)
    capturedStage = clamp(stage + sizeBoost, 0, 3)
  packet.addSpriteFor(defs, spriteId, LabelBurst & " " & $capturedStage,
    proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeBurst(capturedStage))
  let art = cachedSprite(spriteId,
    proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeBurst(capturedStage))
  currentIds.add(BurstObjectId)
  packet.addBoardObject(BurstObjectId, pxOf(sim.lastFx.x) - halfLogical(art.w),
    pxOf(sim.lastFx.y) - halfLogical(art.h), 4000, MapLayerId, spriteId)
  if sim.lastFx.lift:
    packet.addSpriteFor(defs, LiftChipSpriteId, LabelLiftChip,
      proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeLiftChip())
    currentIds.add(LiftChipObjectId)
    packet.addBoardObject(LiftChipObjectId, pxOf(sim.lastFx.x) - 48,
      pxOf(sim.lastFx.y) - 70, 4001, MapLayerId, LiftChipSpriteId)

proc addOutStamp(sim: SimServer, defs: var seq[SpriteDefinition],
                 currentIds: var seq[int], packet: var seq[uint8]) =
  ## A ring-out draws the losing bug tumbling past the rim with an OUT stamp
  ## that holds for the whole reset hold — the idea's stated highlight.
  if sim.phase != RoundReset:
    return
  for b in 0 ..< BodyCount:
    if not sim.bodies[b].outsideRing(sim.ringRadiusNow):
      continue
    let captured = b
    packet.addSpriteFor(defs, OutStampSpriteBase + b, LabelOutStamp & " " & $b,
      proc (): tuple[w, h: int, pixels: seq[uint8]] = bakeOutStamp(captured))
    let objectId = OutStampObjectBase + b
    currentIds.add(objectId)
    packet.addBoardObject(objectId, pxOf(sim.bodies[b].px) - 100,
      pxOf(sim.bodies[b].py) - 100, 4100, MapLayerId, OutStampSpriteBase + b)

proc addBubbles(sim: SimServer, defs: var seq[SpriteDefinition],
                currentIds: var seq[int], packet: var seq[uint8],
                lines: array[BodyCount, string]) =
  ## At most TWO bubbles at a time (one per bug), drawn in a RESERVED BAND
  ## across the top of the arena and never positioned relative to a bug. The
  ## band is sized from `MaxSayRunes` measured in `data/font.ttf`, which is
  ## exactly the reservation the cogchemists 2026-08-24 scar demands.
  for b in 0 ..< BodyCount:
    if lines[b].len == 0:
      continue
    let
      k = boardScale
      bubbleW = BubbleWidthPx * k
      bubbleH = BubbleBandHeightPx * k
      text = alias(b) & ": " & lines[b]
      spriteId = BubbleSpriteBase + b
      pal = BugPalettes[b]
      capturedText = text
      capturedPal = pal
    let bubbleLabel = labelSay(b, text)
    if defs.spriteNeeded(spriteId, bubbleW, bubbleH, bubbleLabel):
      packet.addSpriteChanged(defs, spriteId, bubbleW, bubbleH,
        textPixels(capturedText, bubbleW, bubbleH,
          BubbleFontPx * float(k), ChalkInk,
          ColorRGBX(r: capturedPal.hull.r, g: capturedPal.hull.g,
            b: capturedPal.hull.b, a: 255), 200),
        bubbleLabel)
    let
      objectId = BubbleObjectBase + b
      x = if b == 0: 40 else: MapWidth - BubbleWidthPx - 40
    currentIds.add(objectId)
    packet.addBoardObject(objectId, x, BubbleBandTopPx, 4200, MapLayerId,
      spriteId)

proc buildBoardInit(defs: var seq[SpriteDefinition]): seq[uint8] =
  ## The initial snapshot: the map layer, its viewport at `boardScale` (the
  ## client fits whatever viewport it is told, so the scaled board lands in the
  ## same screen rect with boardScale x the pixels), and the static bands.
  result = @[]
  result.addU8(0x04)                             ## clear objects
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, MapWidth * boardScale, MapHeight * boardScale)
  addMapBands(defs, result)

proc bubbleLines(sim: SimServer): array[BodyCount, string] =
  ## The two spectator lines, taken from the most recent `intent` records. They
  ## are FEED text, never simulation state, so nothing here is hashed.
  for record in sim.feedIntents:
    try:
      let node = parseJson(record)
      if node{"k"}.getStr() != "intent":
        continue
      let body = node{"body"}.getInt(-1)
      if body >= 0 and body < BodyCount:
        result[body] = node{"say"}.getStr()
    except CatchableError:
      discard

proc buildBoard(sim: SimServer, defs: var seq[SpriteDefinition],
                currentIds: var seq[int], packet: var seq[uint8]) =
  addRimArc(sim, defs, currentIds, packet)
  addBugs(sim, defs, currentIds, packet)
  addContactFx(sim, defs, currentIds, packet)
  addOutStamp(sim, defs, currentIds, packet)
  addBubbles(sim, defs, currentIds, packet, bubbleLines(sim))

proc buildSpriteProtocolPlayerUpdates*(sim: var SimServer, playerIndex: int,
                                       state: PlayerViewerState,
                                       nextState: var PlayerViewerState,
                                       spritesOff = false): seq[uint8] =
  ## One seat's per-tick frame. THE GAME IS PERFECT-INFORMATION ON THE
  ## PHYSICS: the ring is lit and both bodies are in it, so the frame carries
  ## the ring, the current rim radius, both bugs with all eight feet, both tilt
  ## gauges and both round tallies. Board labels carry ONLY `BUG-1` / `BUG-2`.
  result = @[]
  nextState = if state.isNil: initPlayerViewerState() else: state
  boardScale = 1
  if not nextState.initialized:
    result = buildBoardInit(nextState.spriteDefs)
    nextState.initialized = true
  var currentIds: seq[int] = @[]
  buildBoard(sim, nextState.spriteDefs, currentIds, result)
  if not state.isNil:
    for objectId in state.objectIds:
      if objectId notin currentIds:
        result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc buildSpriteProtocolUpdates*(sim: var SimServer,
                                 state: GlobalViewerState,
                                 nextState: var GlobalViewerState): seq[uint8] =
  ## The spectator BOARD frame, emitted at the supersampled render scale.
  result = @[]
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  nextState.clickPending = false
  boardScale = boardRenderScaleFor(MapWidth, MapHeight)
  defer: boardScale = 1
  if not nextState.initialized:
    result = buildBoardInit(nextState.spriteDefs)
    nextState.initialized = true
  var currentIds: seq[int] = @[]
  buildBoard(sim, nextState.spriteDefs, currentIds, result)
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Bakes the supersampled board plate BEFORE the listener opens: a viewer's
  ## first-message clock starts at its successful connect (the coworld
  ## certifier allows only seconds), so nothing may be accepted until every
  ## frame the loop will ever build can be assembled instantly.
  let k = boardRenderScaleFor(MapWidth, MapHeight)
  if mapBandsCache.len == 0 or mapBandsDefs.len == 0 or
      mapBandsDefs[0].width != MapWidth * k:
    let saved = boardScale
    boardScale = k
    var
      defs: seq[SpriteDefinition] = @[]
      packet: seq[uint8] = @[]
    addMapBands(defs, packet)
    boardScale = saved
  discard boardTypeface()
