# Training

## Numeric Metta RL and PufferLib

Both certified variants use the headless simulator and each seat's exact
player-visible view. Build the persistent bridge and play complete scripted
and random matches:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/physics-bodies-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/physics-bodies-train-bridge
```

Pass the binary, `coworld_manifest_template.json`, and `default` or `blitz`
to `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` in Metta, with `players=2` and a finite
`total_timesteps`. The 85-feature observation excludes the other seat's
intent. Seven action heads select stance, aim, bearing, aggression, posture,
lead time, and circling direction. Both seats decide against one pre-turn
state. The score is the game's zero-sum match score.

## Metta post-training data

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
examples fit a 4,096-token context with the Qwen2.5-0.5B-Instruct tokenizer
(maximum: 1,646 tokens). One CPU optimizer step with a local tiny
model reduced held-out loss from 1.7463 to 1.7401 for both variants. These
examples distill the scripted teacher; they do not establish stronger league
play.
