#!/usr/bin/env bash
# One-shot weight fetch into the bind-mounted /app/models volume.
# Run:  podman compose run --rm --entrypoint download-weights.sh musetalk
# Idempotent: skips if the key files already exist.
set -euo pipefail
cd /app

need=(
  models/musetalkV15/unet.pth
  models/musetalkV15/musetalk.json
  models/sd-vae/diffusion_pytorch_model.bin
  models/whisper/pytorch_model.bin
  models/dwpose/dw-ll_ucoco_384.pth
  models/syncnet/latentsync_syncnet.pt
  models/face-parse-bisent/79999_iter.pth
  models/face-parse-bisent/resnet18-5c106cde.pth
)
missing=0
for f in "${need[@]}"; do [ -f "$f" ] || missing=1; done
if [ "$missing" = 0 ]; then echo "All weights present."; exit 0; fi

# Do NOT run upstream's download_weights.sh: it does `pip install -U
# huggingface_hub[cli]` (-> 1.x, which drops `huggingface-cli`) and calls
# `gdown --id` (removed in gdown 6), and it has no `set -e`, so it reports
# success after failing. Same downloads, using the tools pinned in the image.
CK=models
mkdir -p $CK/musetalk $CK/musetalkV15 $CK/syncnet $CK/dwpose $CK/face-parse-bisent $CK/sd-vae $CK/whisper

hf() { huggingface-cli download "$@"; }
hf TMElyralab/MuseTalk --local-dir $CK --include "musetalk/musetalk.json" "musetalk/pytorch_model.bin"
hf TMElyralab/MuseTalk --local-dir $CK --include "musetalkV15/musetalk.json" "musetalkV15/unet.pth"
hf stabilityai/sd-vae-ft-mse --local-dir $CK/sd-vae --include "config.json" "diffusion_pytorch_model.bin"
hf openai/whisper-tiny --local-dir $CK/whisper --include "config.json" "pytorch_model.bin" "preprocessor_config.json"
hf yzd-v/DWPose --local-dir $CK/dwpose --include "dw-ll_ucoco_384.pth"
hf ByteDance/LatentSync --local-dir $CK/syncnet --include "latentsync_syncnet.pt"
gdown 154JgKpzCPW82qINcVieuPH3fZ2e0P812 -O $CK/face-parse-bisent/79999_iter.pth
curl -fL https://download.pytorch.org/models/resnet18-5c106cde.pth -o $CK/face-parse-bisent/resnet18-5c106cde.pth

for f in "${need[@]}"; do
  [ -f "$f" ] || { echo "STILL MISSING: $f (fetch manually, see upstream README)" >&2; exit 1; }
done
echo "Weights ready."
