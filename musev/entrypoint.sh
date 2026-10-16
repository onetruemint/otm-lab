#!/usr/bin/env bash
# Activate upstream's conda env, set PYTHONPATH like upstream's Space Dockerfile, run the Gradio app.
set -euo pipefail

# conda location in the upstream image is unverified; try PATH first, then common prefixes.
if command -v conda >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(conda info --base)/etc/profile.d/conda.sh"
else
  for c in /opt/conda /root/miniconda3 /root/anaconda3 /usr/local/miniconda3; do
    [ -f "$c/etc/profile.d/conda.sh" ] && { source "$c/etc/profile.d/conda.sh"; break; }
  done
fi
conda activate musev

R=/app/MuseV
export PYTHONPATH="$R:$R/MMCM:$R/diffusers/src:$R/controlnet_aux/src:${PYTHONPATH:-}"

# Fail early with a readable message if weights were never downloaded.
# Layout from the HF repo is checkpoints/motion/<variant>/unet/..., not checkpoints/<variant>.
if ! compgen -G "$R/checkpoints/motion/musev/unet/*.bin" >/dev/null && ! compgen -G "$R/checkpoints/motion/musev/unet/*.safetensors" >/dev/null; then
  echo "No MuseV checkpoints in $R/checkpoints. Run download-checkpoints.sh first." >&2
  exit 1
fi

cd "$R/scripts/gradio"
exec python app.py
