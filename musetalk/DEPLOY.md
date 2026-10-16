# MuseTalk on otm-lab: deployment

Runtime: **Rootless Podman Compose** (needs the host GPU, CONTEXT.md §6.B).
Route: `musetalk.mint` -> Pi-hole -> k3s Traefik -> selector-less Service + EndpointSlice -> `192.168.50.247:7860`.

## Files

| File | Destination on host (`/home/mint/containers`) |
|---|---|
| `Containerfile`, `download-weights.sh` | `musetalk/` |
| `compose-service.yml` | merge into `compose/docker-compose.yml` under `services:` |
| `k8s-musetalk-bridge.yaml` | append to `k8s/ingress.yaml` |

`musetalk/` already holds an older Quadlet setup (`setup.sh`, `Containerfile`, `musetalk.container`) that I could not see. Not running now. Back up or replace its `Containerfile`; **do not enable the Quadlet unit alongside the Compose service** (both want port 7860 and the GPU).

## Steps

1. Copy files into place; create dirs: `mkdir -p musetalk/models musetalk/results`.
2. Add to `compose/.env`: `MUSETALK_IMAGE=localhost/musetalk:1.5-r1`.
3. Build (long, ~10GB+ image):
   `cd compose && podman compose build musetalk`
   Then set `MUSETALK_REF` to a commit SHA that worked.
4. Fetch weights once (~9GB, into `musetalk/models`):
   `podman compose run --rm --entrypoint download-weights.sh musetalk`
5. **Firewall (needs your approval):**
   `sudo firewall-cmd --zone=FedoraServer --add-port=7860/tcp --permanent && sudo firewall-cmd --reload`
   Then `firewall-cmd --zone=trusted --list-interfaces` should still show `cni0` and `podman1`.
6. Start only this service (do NOT use `start.sh`, it bounces DNS):
   `podman compose up -d musetalk` then `podman logs -f musetalk`.
7. Route: `sudo k3s kubectl apply --dry-run=server -f k8s/ingress.yaml`, then apply for real.
8. Pi-hole Local DNS: `musetalk.mint -> 192.168.50.247`.
9. Verify **from another LAN device**: `curl -sI http://musetalk.mint/`. Also `sudo k3s kubectl get svc -A | grep LoadBalancer` should list only `traefik`.
10. Commit `musetalk/`, compose, and k8s changes. Never commit `.env`; add `musetalk/models/` and `musetalk/results/` to `.gitignore`.

## 8GB VRAM notes

- `--use_float16` is on by default. Use short clips and small batch sizes.
- **Ollama shares this GPU.** A resident model can starve MuseTalk. Before a run, free VRAM: `podman exec ollama ollama stop <model>` (check `nvidia-smi`).
- If you hit CUDA OOM, lower resolution/length first; `expandable_segments` is not available on the pinned torch 2.0.1, so do not set it (it crashes at CUDA init).
- Inference is not instant: expect this to run as a queued Gradio job.

## Unverified, check on first run

- Whether upstream `app.py` accepts `--use_float16` (the upstream docs list the flag for inference; I could not confirm it for `app.py`). If it errors, drop the flag from `command:` and the Containerfile `CMD`.
- `app.py` ignores `GRADIO_SERVER_NAME`/`PORT` (it launches with `--ip`, default 127.0.0.1, which gives Bad Gateway); the command passes `--ip 0.0.0.0`.
- `download_weights.sh` upstream layout vs the checklist in `download-weights.sh` (based on the `./models` tree in the upstream docs). The script fails loudly if any file is missing.
- `mim install mmcv==2.0.1` normally pulls a prebuilt cu118/torch2.0 wheel. If it compiles from source, build time rises sharply.
- No TLS, LAN only, no auth on the Gradio UI (consistent with the rest of the lab).
