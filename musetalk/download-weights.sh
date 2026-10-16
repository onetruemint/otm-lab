#!/usr/bin/env bash
# One-shot weight fetch into the bind-mounted /app/models volume.
# Run:  podman compose run --rm --entrypoint download-weights.sh musetalk
# Idempotent: skips if the key files already exist.
set -euo pipefail
cd /app

need=(
  models/musetalkV15/unet.pth
  models/musetalkV15/musetalk.json
  models/sd-vae-ft-mse/diffusion_pytorch_model.bin
  models/whisper/pytorch_model.bin
  models/dwpose/dw-ll_ucoco_384.pth
  models/syncnet/latentsync_syncnet.pt
  models/face-parse-bisent/79999_iter.pth
  models/face-parse-bisent/resnet18-5c106cde.pth
)
missing=0
for f in "${need[@]}"; do [ -f "$f" ] || missing=1; done
if [ "$missing" = 0 ]; then echo "All weights present."; exit 0; fi

# Prefer upstream's own script: it knows the current layout.
if [ -f download_weights.sh ]; then
  bash download_weights.sh
else
  echo "Upstream download_weights.sh not found in /app" >&2
  exit 1
fi

for f in "${need[@]}"; do
  [ -f "$f" ] || { echo "STILL MISSING: $f (fetch manually, see upstream README)" >&2; exit 1; }
done
echo "Weights ready."
