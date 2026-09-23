# Metta post-training data

The native simulator and published `pusher` policy export supervised examples
for both certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/physics-bodies-default 10 1 default
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/physics-bodies-blitz 10 1 blitz
```

Each run reads the variant config from the manifest and adds the per-seat
tokens supplied by the hosted platform. It plays complete seeded matches with
the native simulator. Examples contain the hosted system prompt, each seat's
own observation, and a `pusher` intent accepted by the game's reply parser.
The parsed intent drives the controller and simulator. Entire matches stay in
one split. The export manifest records source revision, variant, scores, wins,
and row counts. Existing output directories are never overwritten.

Train either output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/physics-bodies-default \
  --output /tmp/physics-bodies-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

The local 10-match exports contained 804 training and 202 validation examples
for default, and 480 training and 120 validation examples for blitz. All 1,606
examples fit a 4,096-token context. One CPU optimizer step with a local tiny
model reduced held-out loss from 1.7463 to 1.7401 for both variants. These
examples distill the scripted teacher; they do not establish stronger league
play.
