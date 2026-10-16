# CONTEXT.md — otm-lab homelab

Reference for agents that do **not** run on this host. Verified against the live host 2026-10-16. Things marked **(unverified)** could not be checked from a non-root shell.

## 1. Topology

One physical host, hostname `ai`, Fedora (kernel 7.x), LAN IP **`192.168.50.247`** (iface `enp4s0`), NVIDIA RTX 4060 Ti. It runs two container systems side by side:

| System | Runs as | Manages | Used for |
|---|---|---|---|
| **Rootless Podman** (user `mint`, uid 1000) via `podman compose` | user | `compose/docker-compose.yml` | Stateful / GPU / infra: `pihole`, `ollama`, `open-webui`, `postgres`, `musetalk` (GPU, built locally), plus helpers `socket-proxy`, `netns-fix` |
| **k3s** single node (`ai`, control-plane) | root | `k8s/*.yaml` | HTTP ingress (bundled Traefik) and migrated apps (`metube`) in namespace `homelab` |

Direction of travel: **migrate apps from Compose to k3s**; `ollama` and `pihole` stay on Compose permanently. `postgres` and `open-webui` compute are still on Compose (only open-webui's *routing* goes via k3s). See `docs/k3s-migration-handoff.md` for history and remaining todo.

Repo root on host: `/home/mint/containers` (git, branch `main`). `README.md` still refers to root-level draft manifests that are now `k8s/wip-*.yaml`.

## 2. Request path (how a URL reaches a service)

```
client ──DNS──> Pi-hole (192.168.50.247:53)  resolves *.mint -> 192.168.50.247
client ──HTTP :80──> k3s Traefik (Service traefik/kube-system, type LoadBalancer via ServiceLB, EXTERNAL-IP 192.168.50.247)
        └─ Ingress host rule ─> Service in ns `homelab`
              ├─ k8s-native app:   Service -> Pod            (metube)
              └─ Compose-hosted:   selector-less Service + hand-written EndpointSlice -> 192.168.50.247:<host-published port>
```

Live hostnames (HTTP only, no TLS): `ytmp3.mint` (metube, k8s), `ai.mint` (open-webui :3000, Compose), `ollama.mint` (:11434, Compose), `musetalk.mint` (:7860, Compose, Gradio UI, no auth), `pihole.mint` (:8089, Compose, redirects `/` → `/admin`), `traefik.mint` (Traefik dashboard, `IngressRoute` in `k8s/traefik-dashboard.yaml`).

- **Traefik is the only ingress, and owns host ports 80/443.** Never run a second thing that binds 80/443 (Compose Traefik was removed for exactly this reason).
- `.mint` is a private TLD served only by Pi-hole. New hostnames need a **Pi-hole Local DNS record** `<name>.mint -> 192.168.50.247` (Pi-hole web UI → Settings → Local DNS, or the `hosts/custom.list` under `compose/etc-pihole/`; that dir is owned by a container subuid, so edit via the UI or `podman unshare`) **(exact existing record mechanism unverified)**. Without it the Ingress is unreachable by name.

## 3. Hard-won host constraints (do not "clean up")

1. **`netns-fix` Compose service is load-bearing.** k3s loads `br_netfilter`, which breaks Podman's `aardvark-dns` (container name resolution). `netns-fix` runs `sysctl net.bridge.bridge-nf-call-iptables=0` inside aardvark-dns's netns on every `compose up`. Keep it, and keep `pihole` `depends_on` it.
2. **k3s `/etc/rancher/k3s/config.yaml` must NOT disable `traefik` or `servicelb`** (the disable list is deliberately empty). Re-adding them takes down every `*.mint` hostname.
3. **firewalld:** `cni0` (k3s bridge) and `podman1` (Podman bridge) are in the `trusted` zone; `FedoraServer` zone has TCP `11434,3000,8089,7860` (pods → Compose services) and NodePorts `30080-32767`. **Any new Compose service that k3s pods/Traefik must reach needs its host-published port added to `FedoraServer`** (`sudo firewall-cmd --zone=FedoraServer --add-port=<p>/tcp --permanent && sudo firewall-cmd --reload`). Firewall loosening needs explicit user approval. Re-verify with `firewall-cmd --zone=trusted --list-interfaces` after OS updates/firewalld reloads.
4. **Rootless Podman `pasta` cannot hairpin** to the host's own LAN IP on unmapped ports, so Podman containers cannot easily reach into k3s. Compose → k3s traffic is therefore avoided; k3s → Compose via host-published ports is the supported direction.
5. **Test routing from a different LAN device**, not `curl 127.0.0.1` on the host — loopback bypasses firewalld and gives false passes.
6. Compose network `homelab`: subnet `10.89.1.0/24`, `socket-proxy` pinned to `10.89.1.2`. k3s pod CIDR `10.42.0.0/16`, service CIDR `10.43.0.0/16`.

## 4. Access & tooling on the host

- Podman: `podman`, `podman compose` (the `docker compose` shim). **No `podman-compose`, no helm CLI.** (Helm is done declaratively through k3s `HelmChart`/`HelmChartConfig` CRs.)
- k3s kubeconfig `/etc/rancher/k3s/k3s.yaml` is root-only: use **`sudo k3s kubectl ...`** (plain `kubectl` as `mint` fails with permission denied).
- Compose must run from `compose/` or with explicit `--env-file`/`-f`. Restart whole stack: `./compose/start.sh` (does `down` then `up -d` — this briefly kills DNS/Pi-hole and the `ollama`/`open-webui` backends; `netns-fix` re-applies on up).
- Secrets live in `compose/.env` (gitignored; image refs `*_IMAGE`, `MASTER_PASS` for Pi-hole, `POSTGRES_PASSWORD`, `WEBUI_SECRET_KEY`). **Never print or commit them.** `compose/etc-pihole/` (Pi-hole live data, incl. keys) is also gitignored.
- GPU: NVIDIA via CDI. In Compose use `devices: [nvidia.com/gpu=all]`; in Quadlet `AddDevice=nvidia.com/gpu=all` + `SecurityLabelDisable=true` (SELinux). CDI spec at `/etc/cdi/nvidia.yaml`.
- Images are pinned via `.env` tags (Compose) or digest (k8s, e.g. `metube@sha256:...`).

## 5. Repo layout

```
compose/docker-compose.yml   Compose stack (postgres, open-webui, ollama, pihole, socket-proxy, netns-fix)
compose/.env                 secrets + image tags (gitignored)
compose/etc-pihole/          Pi-hole state (gitignored)
compose/start.sh             down+up the stack
k8s/metube.yaml              reference-quality manifest: Namespace homelab, PVC, Deployment, Service
k8s/ingress.yaml             all Ingresses + Service/EndpointSlice bridges to Compose services
k8s/traefik-config.yaml      HelmChartConfig (Traefik --api.insecure=true)
k8s/traefik-dashboard.yaml   Traefik CRDs: pihole redirect Middleware, traefik.mint IngressRoute
k8s/wip-*.yaml               `podman generate kube` drafts (open-webui, postgres) — NOT appliable as-is
ollama/deploy.sh             copies ollama/models/*.model into the ollama container and `ollama create`s them
musetalk/                    Containerfile + download-weights.sh + DEPLOY.md for the `musetalk` Compose service (built from ../musetalk, upstream pinned by SHA via build arg MUSETALK_REF); models/ and results/ are gitignored bind mounts
docs/k3s-migration-handoff.md  history + remaining migration todo
```

## 6. Deploying a new service from scratch

### Step 0 — choose the runtime
- **Default: k3s.** Stateless or PVC-backed HTTP apps → manifest in `k8s/<app>.yaml`.
- **Podman (Compose)** only if it needs: the host GPU, raw host ports like 53/udp, or is Pi-hole/ollama-adjacent infra. A Quadlet is an alternative for standalone boot services, but nothing uses it now.
- Postgres/open-webui are mid-migration; don't add dependents that assume either location without checking `docs/`.

### A. New service on k3s (preferred path)

1. **Write `k8s/<app>.yaml`**, copying the structure of `k8s/metube.yaml`:
   - `namespace: homelab` (already exists; metube.yaml creates it, re-declaring is harmless).
   - `PersistentVolumeClaim` if stateful: default StorageClass is **`local-path`** (omit `storageClassName`), `ReadWriteOnce`, data lives on this host's disk.
   - `Deployment`: `replicas: 1`, **`strategy: Recreate`** when a RWO PVC is mounted, label `app.kubernetes.io/name: <app>`, **pin image by digest or exact tag** (not `:latest`), resource requests/limits, `securityContext` (runAsNonRoot, drop ALL caps, no privilege escalation, `seccompProfile: RuntimeDefault`), readiness + liveness probes. Use `PUID/PGID=1000` for linuxserver-style images.
   - `Service`: use **`ClusterIP`** (metube's NodePort 30081 is a legacy debug aid; do not add new `LoadBalancer` Services — the only one allowed is Traefik's).
   - Secrets: create with `sudo k3s kubectl -n homelab create secret generic ...` (not committed); reference via `secretKeyRef`.
2. **Add an `Ingress`** (no `ingressClassName` needed; Traefik is the default):
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata: {name: <app>, namespace: homelab}
   spec:
     rules:
       - host: <app>.mint
         http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: <app>, port: {number: <port>}}}}]}
   ```
   Put it in `k8s/ingress.yaml` (or alongside the app). Redirects/middleware/anything Ingress can't express → Traefik CRDs (`traefik.io/v1alpha1`) in `k8s/traefik-dashboard.yaml`, referenced via annotation `traefik.ingress.kubernetes.io/router.middlewares: homelab-<name>@kubernetescrd`.
3. **Validate, then apply:**
   ```
   sudo k3s kubectl apply --dry-run=server -f k8s/<app>.yaml
   sudo k3s kubectl apply -f k8s/<app>.yaml
   sudo k3s kubectl -n homelab rollout status deploy/<app>
   sudo k3s kubectl -n homelab logs deploy/<app> --tail=50
   ```
4. **Add the DNS record** `<app>.mint -> 192.168.50.247` in Pi-hole (§2).
5. **Verify from another LAN device**: `curl -sI http://<app>.mint/` (§3.5). Also confirm no stray LoadBalancer: `sudo k3s kubectl get svc -A | grep LoadBalancer` → only `traefik`.
6. Commit manifests (never `.env`/`etc-pihole`).

### B. New service on Podman Compose

1. Add a block to `compose/docker-compose.yml`: `container_name`, `image: ${<NAME>_IMAGE}` (add the tag to `.env`), `restart: unless-stopped`, `networks: [homelab]`, named volume (declare under top-level `volumes:`) or bind mount with `:z` (SELinux), secrets via `.env` interpolation (escape literal `$` as `$$`). GPU: `devices: [nvidia.com/gpu=all]`.
2. Publish a **host port** (`"<host>:<container>"`) if anything outside the Compose network must reach it.
3. Apply: `cd compose && podman compose up -d <service>` (avoid full `start.sh` unless needed; it bounces DNS). Keep `netns-fix` untouched.
4. **To expose via a `*.mint` URL**, add to `k8s/ingress.yaml` the three-object bridge used for `ollama`/`open-webui`/`pihole`: a selector-less `Service` (`<app>-ext`), an `EndpointSlice` (label `kubernetes.io/service-name: <app>-ext`, endpoint `192.168.50.247`, the published port), and an `Ingress`. Apply with `sudo k3s kubectl apply -f k8s/ingress.yaml`.
5. **Open the host port in firewalld `FedoraServer` zone** (§3.3, needs user approval), add the Pi-hole DNS record, verify from another LAN device.

### C. Standalone GPU/boot service via Quadlet (optional; no current example, musetalk moved to Compose)
Rootless Quadlet: `~/.config/containers/systemd/<name>.container` (`[Container]` with `Image`, `AddDevice=nvidia.com/gpu=all`, `SecurityLabelDisable=true`, `PublishPort`, `Volume=%h/...`; `[Service] Restart=on-failure`; `[Install] WantedBy=default.target`), then `systemctl --user daemon-reload && systemctl --user start <name>`, `sudo loginctl enable-linger $USER` for boot start. Outside both Compose and k3s: if a `.mint` URL is wanted, bridge it with the §B.4 pattern (open its port in firewalld too).

### Worked example: musetalk (GPU app on Compose, built locally)
See `musetalk/DEPLOY.md`. Compose `build:` with context `../musetalk`; pin third-party source by commit SHA build arg; pin Python deps that conflict (e.g. `huggingface_hub<1.0` because transformers 4.39.2 rejects 2.x). Weights live in a gitignored bind mount; fetch with `podman compose run --rm --entrypoint download-weights.sh musetalk`. Free GPU VRAM before runs (`podman exec ollama ollama stop <model>`); the 4060 Ti's VRAM is shared with ollama.

### Ollama models
Custom models: drop `<name>.model` Modelfiles in `ollama/models/` and run `./ollama/deploy.sh ollama/models` (default src dir is `./modelfiles`, so pass the path). Requires the `ollama` container running.

## 7. Pitfalls checklist for agents

- Don't run `kubectl apply` on `k8s/wip-*.yaml`.
- `traefik-dashboard.yaml` needs Traefik CRDs present (they are, as of now).
- Don't re-enable a second ingress controller or bind 80/443 elsewhere.
- Don't remove `netns-fix`, change the k3s `disable` list, or move `cni0`/`podman1` out of `trusted`.
- Don't `curl 127.0.0.1` to claim a route works; test from another LAN host.
- Ask the user before firewall changes, deleting volumes, or `compose down` of the whole stack (takes down DNS for the LAN).
- `postgres` on Compose is not wired to anything and is on the `homelab` Compose network only (not reachable from k3s without a published port).
- No TLS anywhere; all `*.mint` is plain HTTP on the LAN.
