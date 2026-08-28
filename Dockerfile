# Build Docker. ONE image, TWO entrypoints: /bin/physics-bodies (the game
# server, which also runs the whole decision layer) and
# /bin/physics-bodies-player (the thin seat registrar). The policy set is
# env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED), which
# is what keeps a champion and a scripted filler byte-identical apart from
# their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/bodies
COPY nimby.lock .
RUN nimby --global sync nimby.lock

# The committed nim.cfg pins the AUTHOR's package paths; rebuild it from THIS
# container's synced tree (the same recipe ci.yml's test job runs).
COPY . .
RUN rm -f nim.cfg && \
  for pkg in "$HOME"/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/physics-bodies-nimcache \
  --out:physics-bodies \
  src/physics_bodies.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/physics-bodies-player-nimcache \
  --out:physics-bodies-player \
  src/physics_bodies_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/bodies
COPY --from=build /workspace/bodies/physics-bodies /bin/physics-bodies
COPY --from=build /workspace/bodies/physics-bodies-player \
  /bin/physics-bodies-player
COPY --from=build /workspace/bodies/*.json ./
COPY --from=build /workspace/bodies/data ./data
COPY --from=build /workspace/bodies/client ./client

CMD ["/bin/physics-bodies"]
