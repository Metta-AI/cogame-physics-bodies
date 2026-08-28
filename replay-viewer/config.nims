import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup). With Nim's bundled allocator a bad free silently poisons
# the freelists; dlmalloc traps loudly instead, which is how the
# use-after-free fixed in bodies_replay.nim (emscripten_exit_with_live_runtime)
# was found. Keep this so any future stale free crashes at the fault instead
# of corrupting replay playback at a distance.
--define:useMalloc

# ENVIRONMENT includes worker because the shipped static bundle owns the WASM
# runtime in a Dedicated Worker, and node so CI can smoke-run that EXACT emitted
# module (tools/wasm_replay_smoke.cjs) — wasm32-only failures (int overflow traps,
# 2 GB address-space exhaustion) are invisible to the native 64-bit tests.
# ABORTING_MALLOC matters: with -d:useMalloc Nim never checks malloc for
# nil (that path is `when defined(zephyr)`-only), and wasm32 has no memory
# protection, so a failed allocation would otherwise write the seq header
# through the nil pointer into address 0 — silently corrupting the module's
# own globals, which is how oversized replays died with an EMPTY
# bodies_error_len(). Aborting keeps linear memory intact, and the page reads
# bodies_stage_ptr/len afterwards to report what the runtime was doing.
# client/art is preloaded (below) because the RENDERER reads it at runtime:
# global.nim:447 opens client/art/walls/wall_v.jpg while baking the board plate,
# and under emscripten that path has to exist in MEMFS or the bake raises inside
# the worker with no other symptom than a board that never draws. It is the one
# link-flag change beyond the two renames ctf's file needed (r1 review N16).
#
# NOTHING INSIDE THE STRING BELOW IS A COMMENT. It is one emcc command line
# with the newlines replaced by spaces, so a `#` line inside it is passed
# THROUGH to the linker and swallows every flag after it on the same line:
# EXPORTED_FUNCTIONS went missing that way and the page died with
# "Module._malloc is not a function" (CI run 33176949006).
switch(
  "passL",
  (&"""
  -o {distDir / "bodies_replay.js"}
  --preload-file {rootDir / "data"}@data
  --preload-file {rootDir / "client" / "art"}@client/art
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s FILESYSTEM=1
  -s ENVIRONMENT=web,worker,node
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_bodies_load_replay,_bodies_frame,_bodies_input,_bodies_packet_ptr,_bodies_packet_len,_bodies_mismatch_tick,_bodies_error_ptr,_bodies_error_len,_bodies_stage_ptr,_bodies_stage_len
  """).replace("\n", " ")
)
