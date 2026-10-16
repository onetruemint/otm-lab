#!/usr/bin/env bash
# One-shot checkpoint fetch into the bind-mounted checkpoints dir.
# Run: podman compose run --rm --entrypoint download-checkpoints.sh musev
# Resumable: re-run if interrupted. Large download (tens of GB).
set -euo pipefail

if command -v conda >/dev/null 2>&1; then
  source "$(conda info --base)/etc/profile.d/conda.sh"
else
  for c in /opt/conda /root/miniconda3 /root/anaconda3 /usr/local/miniconda3; do
    [ -f "$c/etc/profile.d/conda.sh" ] && { source "$c/etc/profile.d/conda.sh"; break; }
  done
fi
conda activate musev

CK=/app/MuseV/checkpoints
mkdir -p "$CK"

# <1.0 on purpose: 2.x drops `huggingface-cli` and breaks the old pinned
# diffusers/transformers in upstream's env. No -U, so an already-satisfying install is kept.
python -m pip install -q "huggingface_hub[cli]<1.0"

# Main weights (motion, musev unet variants, referencenet, base t2i, ...)
# --local-dir-use-symlinks False: otherwise big files become symlinks into the
# container's ephemeral HF cache and vanish with `run --rm`.
huggingface-cli download TMElyralab/MuseV --local-dir "$CK" --local-dir-use-symlinks False

# IP-Adapter pieces upstream references. Fetch only if the repo above didn't include them.
if [ ! -f "$CK/IP-Adapter/models/ip-adapter_sd15.bin" ]; then
  huggingface-cli download h94/IP-Adapter \
    --include "models/image_encoder/*" "models/ip-adapter_sd15.bin" "models/ip-adapter-faceid_sd15.bin" \
    --local-dir "$CK/IP-Adapter" --local-dir-use-symlinks False
fi

echo "Checkpoints in $CK:"
ls "$CK"
echo "Upstream example configs also reference base models from Civitai (majicmixRealv6Fp16, fantasticmix_v10);"
echo "download those manually into $CK if you use those configs."
