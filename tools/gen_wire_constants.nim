## Emits the JS wire-constants block (src/bodies/wire_constants.nim) on stdout.
## The static replay-viewer bundle cannot run the server's compile-time splice,
## so Dockerfile.replay-viewer runs this to write dist/wire_constants.js and
## injects a <script src> for it into the dist HTML page — same constants, same
## source, different delivery.
import ../src/bodies/wire_constants

echo WireConstantsJs
