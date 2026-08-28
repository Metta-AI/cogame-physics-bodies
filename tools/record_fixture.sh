#!/usr/bin/env bash
# Records one episode to a .replay file, entirely locally: one game process and
# one player process per seat, no Docker.
#
#   tools/record_fixture.sh <out path> [seed] [maxTicks] [config json overrides]
#
# The output path is repo-relative. The recording is a REAL episode through the
# server's own control path, so it is the same bytes CI's docker-smoke produces.
set -euo pipefail

out="${1:?usage: record_fixture.sh <out path> [seed] [maxTicks] [json]}"
seed="${2:-5104773}"
maxTicks="${3:-1728}"
overrides="${4:-{\}}"
port="${PORT:-8099}"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo}"

work="$(mktemp -d)"
cleanup() {
  kill %1 %2 %3 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

python3 - "${work}/config.json" "${seed}" "${maxTicks}" "${overrides}" <<'PY'
import json, sys
path, seed, max_ticks, overrides = sys.argv[1:5]
config = {
    "players": [{"name": "BUG-1"}, {"name": "BUG-2"}],
    "slots": [{"alias": "BUG-1"}, {"alias": "BUG-2"}],
    "num_agents": 2, "minPlayers": 2, "seed": int(seed),
    "maxTicks": int(max_ticks), "maxGames": 1, "turnTicks": 36,
    "turnSpacingMs": 0, "fastMode": True,
    "tokens": ["token-0", "token-1"],
}
config.update(json.loads(overrides))
with open(path, "w") as handle:
    json.dump(config, handle)
PY

nim c -d:release --path:src -o:"${work}/physics-bodies" src/physics_bodies.nim
nim c -d:release --path:src -o:"${work}/physics-bodies-player" \
  src/physics_bodies_player.nim

COGAME_CONFIG_URI="file://${work}/config.json" \
COGAME_RESULTS_URI="file://${work}/results.json" \
COGAME_SAVE_REPLAY_URI="file://${repo}/${out}" \
COGAME_EVENTS_URI="file://${work}/events.jsonl" \
COGAME_HOST=127.0.0.1 COGAME_PORT="${port}" \
  "${work}/physics-bodies" &

sleep 4
for slot in 0 1; do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:${port}/player?slot=${slot}&token=token-${slot}" \
  PLAYER_SCRIPTED="${PLAYER_SCRIPTED:-pusher}" \
    "${work}/physics-bodies-player" &
done

wait %1
echo "recorded ${out}"
cat "${work}/results.json"
