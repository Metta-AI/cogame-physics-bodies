## 13. Static assertions over the viewer: the inherited chrome, the removed
## elements, and one beat-marker rule per kind the sim emits.

import std/[os, strformat, strutils]
import crunchy/sha256
import bodies/[sim, global]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

let
  page = readFile(repoFile("client/replay_broadcast.html"))
  chrome = readFile(repoFile("client/chrome_common.js"))
  core = readFile(repoFile("client/broadcast_core.js"))
  staticReplay = readFile(repoFile("replay-viewer/static_replay.js"))
  worker = readFile(repoFile("replay-viewer/static_replay_worker.js"))
  viewerConfig = readFile(repoFile("replay-viewer/config.nims"))

## `page` with every `<!-- ... -->` region removed. An UNTERMINATED comment is
## the failure mode that motivated this: surgically deleting the inherited
## `#fpv` markup by line range ate the closing `-->` of the comment above it,
## so the comment ran on and swallowed `#bannerlane`, `#killfeed` and
## `#transport`. Every one of those ids was still present as TEXT, so a plain
## `contains` check passed while the browser rendered no transport at all and
## `renderTransport` died on `$('transport').classList`. Element checks below
## therefore run against `markup`, not `page`.
proc stripComments(html: string): string =
  var i = 0
  while true:
    let open = html.find("<!--", i)
    if open < 0:
      result.add html[i .. ^1]
      return
    result.add html[i ..< open]
    let close = html.find("-->", open + 4)
    doAssert close >= 0,
      "replay_broadcast.html has an UNTERMINATED <!-- comment starting at " &
      "byte " & $open & " — it swallows every element after it"
    i = close + 3

let markup = stripComments(page)

## The starter's copies, if the read-only mount is available. In CI it is not,
## so the byte-identity claim is pinned by SHA-256 instead.
const ChromeCommonSha =
  "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"

# --- chrome_common.js is the starter's, byte for byte ------------------
block:
  var digest = ""
  for value in sha256(chrome):
    digest.add toHex(value, 2).toLowerAscii()
  ## The pin is regenerated whenever the STARTER's file legitimately changes;
  ## what it forbids is editing OUR copy. Every game-specific readout lives in
  ## the appended block instead.
  if digest != ChromeCommonSha:
    echo "NOTE: chrome_common.js sha256 is ", digest
  check digest == ChromeCommonSha,
    "client/chrome_common.js is NOT byte-identical to the inherited copy " &
    "(sha256 " & digest & "). Every game-specific readout belongs in the " &
    "appended game block."
  check chrome.contains("window.ChromeCommon = function (ctx)"),
    "chrome_common.js is not the shared chrome module"

# --- broadcast_core.js differs in EXACTLY the wire identifier ----------
block:
  check core.contains("BODIES_WIRE"),
    "broadcast_core.js does not read window.BODIES_WIRE"
  check not core.contains("CTF_WIRE"),
    "broadcast_core.js still reads the starter's wire global"

# --- the inherited chrome the page must keep --------------------------
block:
  for marker in ["function relayout()", "--hudscale", "--topband", "--band",
                 "#endcard {", "bottom: var(--band"]:
    check page.contains(marker),
      &"replay_broadcast.html no longer contains `{marker}` — relayout() and " &
      "the transport band are the inherited chrome"
  for id in ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
             "chrome", "scorebug", "plates-l", "plates-r", "clock",
             "clock-time", "clock-caption", "mmwarn", "bannerlane",
             "killfeed", "transport", "btn-play", "btn-back", "btn-fwd",
             "btn-end", "btn-restart", "btn-loop", "btn-skip", "btn-spoilers",
             "speedchips", "scrub", "scrub-fill", "scrub-head", "scrub-win",
             "momentum", "lulls", "tick-clock", "ffwd-chip", "ffwd-mini",
             "win-chip", "endcard", "ec-headline", "ec-how", "ec-wincond",
             "ec-teams", "ec-replay", "status"]:
    check markup.contains("id=\"" & id & "\""),
      &"replay_broadcast.html lost the inherited element #{id}"
  check page.contains(".tiny"),
    "replay_broadcast.html lost the .tiny (360 px) block"
  ## The round/ring readout is a game-block element of its own (r1 review N15),
  ## so #clock-caption can go on naming the clock. Both must be on screen: the
  ## element is created by the block, so what the page has to carry is its id
  ## and a CSS rule for it.
  check page.contains("#pb-ring {") and page.contains("el.id = 'pb-ring'"),
    "the round/ring caption element #pb-ring is not both styled and created"
  check page.contains("'Round clock'"),
    "#clock-caption no longer names the round clock"

# --- every element the INHERITED chrome dereferences must exist --------
# chrome_common.js is byte-identical and unconditionally does
# `$('transport').classList...` on the first frame. Any id it looks up that the
# page does not declare is a null dereference in the browser, not a no-op.
block:
  var i = 0
  while true:
    let hit = chrome.find("$('", i)
    if hit < 0: break
    let close = chrome.find("')", hit + 3)
    if close < 0: break
    let id = chrome[hit + 3 ..< close]
    i = close + 2
    if id.len == 0 or not id.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-'}):
      continue
    check markup.contains("id=\"" & id & "\""),
      &"chrome_common.js looks up #{id} but replay_broadcast.html does not " &
      "declare it — the inherited chrome will null-dereference on frame 1"

# --- the REMOVED elements, exactly these ------------------------------
block:
  for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
             "zoom-in", "zoom-slider", "zoom-read", "fpv", "fpv-canvas",
             "fpv-hud", "fpv-name", "fpv-hp", "fpv-gear", "fpv-map",
             "fpv-map-canvas", "fpv-cap", "fpv-grip", "povBadge"]:
    check not page.contains("id=\"" & id & "\""),
      &"replay_broadcast.html still declares #{id} — a sumo ring is a FIXED " &
      "arena and the zoom bar, minimap, POV badge and first-person inset are " &
      "removed"
    check not page.contains("$('" & id & "')"),
      &"replay_broadcast.html still wires #{id}"

# --- the appended game block, and its pb- prefix ----------------------
block:
  const banner = "PHYSICS-BODIES additions to the inherited coworld-ctf chrome"
  check page.contains(banner),
    "the appended game block's banner comment is missing"
  let blockStart = page.find(banner)
  let gameBlock = page[blockStart .. ^1]
  ## The chrome alias block declares the shared beat builder with a hoisted
  ## `var`; a game-block function of the same name is silently swallowed by it
  ## (cogame-tandem, 2026-08-23). No top-level name below the banner may
  ## collide with the alias list.
  const aliasNames = ["RED", "BLUE", "AMBER", "PAPER", "GREEN", "YELLOW",
    "TEAM_ORDER", "TEAM_COLOR", "teamCol", "activeTeams", "teamOf",
    "otherTeam", "stripSeatSuffix", "teamPolicies", "teamName", "teamHeadline",
    "rosterName", "setName", "esc", "fmt", "setHandicap", "teamPerkGroups",
    "perkIconsHtml", "togglePov", "renderClock", "renderTransport",
    "ingestLullSpans", "renderLullSpans", "markBeat", "killMarkerTeam",
    "renderBeatMarkers", "captureTeam", "ingestBeats", "setVerdict",
    "ingestLeadSeries", "recordMomentum", "renderMomentum", "getSpoilers",
    "setSpoilers"]
  for name in aliasNames:
    check not gameBlock.contains("function " & name & "("),
      &"the game block declares `{name}`, which shadows the chrome alias block"
    check not gameBlock.contains("var " & name & " ="),
      &"the game block declares `var {name}`, which shadows the alias block"
  ## Its own beat builder is prefixed and draws BUTTONS.
  check gameBlock.contains("function pbBeat("),
    "the game block has no pb-prefixed beat builder"
  check gameBlock.contains("document.createElement('button')"),
    "the game block's scrubber beats are not <button> elements"
  check gameBlock.contains("setAttribute('aria-label'"),
    "the game block's beats carry no aria-label"
  check gameBlock.contains("CTX.send('s:' + tick)"),
    "clicking a beat does not seek to its tick"
  ## No overlay sits INSIDE the transport band.
  check gameBlock.contains("bottom: calc(var(--band, 0px)"),
    "the game block's overlays are not positioned against var(--band)"

# --- a .beat-marker rule for EVERY kind the sim emits -----------------
block:
  ## The kinds the sim's derived beat stream actually produces as scrubber
  ## beats. A kind with no rule draws an unstyled sliver nobody can see.
  const beatKinds = ["knockdown", "ring_out", "round_end", "match_point",
                     "over"]
  for kind in beatKinds:
    check page.contains(".beat-marker." & kind),
      &"no CSS rule for `.beat-marker.{kind}`"
  ## And the two team tints.
  for team in [sideText(0), sideText(1)]:
    check page.contains(".beat-marker." & team),
      &"no CSS rule for `.beat-marker.{team}`"

# --- the 360 px rules ------------------------------------------------
block:
  check page.contains(".plate-name {"),
    "the .plate-name rule is missing"
  let at = page.find(".plate-name {")
  let rule = page[at ..< min(page.len, at + 220)]
  check rule.contains("flex: 1 1 auto") and rule.contains("min-width: 3.2em"),
    "the .plate-name rule does not carry `flex: 1 1 auto` and " &
    "`min-width: 3.2em` — the documented 360 px scorebug failure"
  check page.contains("@media (max-width: 640px)"),
    "there is no under-640 px rule hiding the labels"

# --- the static bundle's markers and bootstrap -----------------------
block:
  check staticReplay.contains("'data-replay-loaded', 'true'"),
    "static_replay.js no longer sets data-replay-loaded on the first frame"
  check staticReplay.contains("'data-replay-error'"),
    "static_replay.js no longer sets data-replay-error on failure"
  check staticReplay.contains("data-replay-mismatch-tick"),
    "static_replay.js no longer reports a hash mismatch"
  check staticReplay.contains("window.BodiesStaticReplay"),
    "static_replay.js does not publish window.BodiesStaticReplay"
  ## The link flags and the JS bootstrap are a MATCHED PAIR, both taken from
  ## the same starter: this shell waits for Module.onRuntimeInitialized, so the
  ## build must NOT modularize (cogame-lantern, 2026-08-23).
  check worker.contains("Module.onRuntimeInitialized"),
    "the worker no longer waits on Module.onRuntimeInitialized"
  check worker.contains("var Module = {}"),
    "the worker no longer declares the non-modularized Module"
  check not viewerConfig.contains("MODULARIZE"),
    "config.nims gained -s MODULARIZE=1, which this shell cannot boot"
  check not viewerConfig.contains("EXPORT_NAME"),
    "config.nims gained -s EXPORT_NAME, which this shell cannot boot"
  check viewerConfig.contains("bodies_replay.js"),
    "config.nims does not emit bodies_replay.js"
  check worker.contains("'./bodies_replay.js'"),
    "the worker does not import the emitted module"
  for exported in ["_bodies_load_replay", "_bodies_frame", "_bodies_input",
                   "_bodies_packet_ptr", "_bodies_packet_len",
                   "_bodies_mismatch_tick", "_bodies_error_ptr",
                   "_bodies_error_len", "_bodies_stage_ptr",
                   "_bodies_stage_len"]:
    check viewerConfig.contains(exported),
      &"config.nims does not export {exported}"

# --- no ctf_ / CTF_ / paintball identifier survives ------------------
block:
  ## `client/chrome_common.js` is EXEMPT and pinned byte-for-byte above: it is
  ## the starter's file, it still names the starter's wire global as its
  ## fallback, and editing it is the thing this suite forbids.
  var offenders: seq[string] = @[]
  for dir in ["client", "replay-viewer", "src"]:
    for path in walkDirRec(repoFile(dir)):
      if path.endsWith("chrome_common.js"):
        continue
      if not (path.endsWith(".nim") or path.endsWith(".js") or
              path.endsWith(".html") or path.endsWith(".nims")):
        continue
      let body = readFile(path)
      for token in ["ctf_", "CTF_", "paintball", "Paintball", "PAINTBALL"]:
        if body.contains(token):
          offenders.add path & " -> " & token
  check offenders.len == 0,
    "a starter identifier survived the rename sweep: " & $offenders

if failures > 0:
  quit("test_viewer: " & $failures & " failure(s)", 1)
echo "test_viewer: ok"
