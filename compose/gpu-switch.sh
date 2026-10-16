#!/usr/bin/env bash
# Hand the single 8GB GPU to exactly one heavy service.
# Usage: ./gpu-switch.sh musetalk | musev | none
# Run from /home/mint/containers/compose (or anywhere; it cd's there).
# Only touches musetalk, musev and Ollama's loaded models. Never `compose down`
# the whole stack (that takes down Pi-hole/DNS).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/../compose" 2>/dev/null || cd /home/mint/containers/compose

target="${1:-}"
case "$target" in musetalk|musev|none) ;; *) echo "usage: $0 musetalk|musev|none" >&2; exit 2 ;; esac

echo "Stopping GPU-heavy services..."
podman compose stop musetalk musev 2>/dev/null || true

echo "Unloading Ollama models (if any)..."
if podman ps --format '{{.Names}}' | grep -qx ollama; then
  podman exec ollama ollama ps | awk 'NR>1 {print $1}' | xargs -r -n1 podman exec ollama ollama stop || true
fi

if [ "$target" != "none" ]; then
  echo "Starting $target..."
  podman compose up -d "$target"
fi

echo; nvidia-smi --query-gpu=memory.used,memory.total --format=csv
echo "Note: Open WebUI / API calls to Ollama will reload a model and reclaim VRAM."
