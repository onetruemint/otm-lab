# MuseV on otm-lab (paired with MuseTalk)

Pipeline: **MuseV** makes a video from an image (+ text prompt), then **MuseTalk** lip-syncs that video to your audio. Two UIs, handed off through the browser (download from `musev.mint`, upload to `musetalk.mint`).

Same pattern as MuseTalk: rootless Podman Compose (GPU), bridged by k3s Traefik.
`musev.mint` -> Pi-hole -> Traefik -> Service/EndpointSlice -> `192.168.50.247:7861`.

## The constraint that shapes everything

Upstream's own numbers: the base `musev/unet` model needs about **8GB** at 512x512, `time_size=12`. The `referencenet` variants need about **12GB**. Your 4060 Ti has 8GB.

- Only `musev/unet` is realistic here, and it will use essentially the whole card. Expect OOM on longer clips or higher resolution; lower resolution / `time_size` first.
- **MuseV, MuseTalk and Ollama cannot share the GPU.** Run one at a time with `gpu-switch.sh`.
- The 12GB variants fit on your workstation's 16GB RTX 5080, but that is a Windows machine outside this stack.

## Files

| File | Destination (`/home/mint/containers`) |
|---|---|
| `musev/Containerfile`, `entrypoint.sh`, `download-checkpoints.sh` | `musev/` |
| `compose-musev.yml` | merge into `compose/docker-compose.yml` under `services:` |
| `k8s-musev-bridge.yaml` | append to `k8s/ingress.yaml` |
| `gpu-switch.sh` | `musetalk/` or any sibling dir of `compose/` (chmod +x) |

## Steps

1. Copy files; `mkdir -p musev/checkpoints`.
2. `.env`: `MUSEV_IMAGE=localhost/musev:r1`.
3. Pull and pin the base image (upstream has only a `latest` tag, ~2 years old):
   `podman pull docker.io/anchorxia/musev:latest`, then set `MUSEV_BASE` in the compose `args:` to `docker.io/anchorxia/musev@sha256:<digest>`.
4. Build: `cd compose && podman compose build musev` (image is large; needs plenty of free space on the 256GB root NVMe, or move Podman storage).
5. Checkpoints (large download):
   `podman compose run --rm --entrypoint download-checkpoints.sh musev`
   Needs a free ~tens of GB under `musev/checkpoints` (put it on the 8TB `/mnt/e` via a symlink if root is tight).
6. **Firewall, needs your approval:**
   `sudo firewall-cmd --zone=FedoraServer --add-port=7861/tcp --permanent && sudo firewall-cmd --reload`
7. Apply route: `sudo k3s kubectl apply --dry-run=server -f k8s/ingress.yaml`, then apply for real.
8. Pi-hole Local DNS: `musev.mint -> 192.168.50.247`.
9. Start: `./gpu-switch.sh musev` (stops MuseTalk and unloads Ollama first).
10. Verify from another LAN device: `curl -sI http://musev.mint/`. `sudo k3s kubectl get svc -A | grep LoadBalancer` should still list only `traefik`.
11. Switch back with `./gpu-switch.sh musetalk` (or `none` to free the GPU for Ollama).

## Workflow

1. `./gpu-switch.sh musev`: open `musev.mint`, generate the clip from an image, download it.
2. `./gpu-switch.sh musetalk`: open `musetalk.mint`, upload the clip + audio, generate.

## Unverified, check on first run

- Conda location and the `musev` env name in the upstream image (entrypoint tries `conda` on PATH, then common prefixes).
- Torch/CUDA inside that old image on an Ada GPU (sm_89). If it falls back to CPU or errors with "no kernel image", the base image needs a newer torch.
- That `scripts/gradio/app.py` finds weights at `/app/MuseV/checkpoints` and honors `GRADIO_SERVER_NAME/PORT`. Upstream documents no flags for it.
- Whether `TMElyralab/MuseV` on Hugging Face already includes the IP-Adapter files; the download script only fetches `h94/IP-Adapter` pieces if they are missing.
- Output files go wherever the Gradio app writes them (not mounted). Download from the UI, or add a volume once you see where it writes.
- No TLS, no auth, LAN only.
