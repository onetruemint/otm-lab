# Handoff: migrate metube, postgres, open-webui from Compose to k3s

## Goal

Move `metube`, `postgres`, and `open-webui` off the Podman Compose stack and onto the k3s cluster. Keep `ollama` and `pihole` on Compose. Preserve the existing friendly URLs (`ai.mint`, `ytmp3.mint`, etc.) resolved via Pi-hole.

## Essential background (read this before touching anything)

This host runs **two container systems that previously fought over the same resources** — a long debugging session traced and fixed three separate k3s-vs-Podman conflicts:

1. k3s loads the `br_netfilter` kernel module on startup, which made Podman's rootless bridge traffic subject to netfilter and broke internal DNS (`aardvark-dns`). Fixed by a `netns-fix` service in `docker-compose.yml` that flips `net.bridge.bridge-nf-call-iptables=0` inside Podman's own network namespace on every restart. **Do not remove this service** — it's load-bearing, not legacy cruft.
2. k3s's bundled Traefik + ServiceLB claimed host ports 80/443 via kube-proxy, silently swallowing all HTTP traffic before Compose's own Traefik ever saw it. Originally fixed by disabling both — **this has since been deliberately reversed, see below.**
3. The orphaned `traefik` Service object left behind in `kube-system` after disabling ServiceLB was still causing kube-proxy to install an active **reject** rule for the node's LAN IP on ports 80/443 (Kubernetes' documented behavior for a LoadBalancer Service with no healthy endpoints). It was deleted at the time (had to clear a stuck finalizer manually).

Bugs #2 and #3 only existed because **two** Traefik instances both wanted ports 80/443 at once. That's no longer the situation — see the next section.

## Architecture (current, as of 2026-10-10): k3s's own Traefik is the single front door

**This reverses the original "no second ingress controller" decision.** The user explicitly chose to stop hand-maintaining a static route per service in Compose's Traefik and instead let k3s's bundled Traefik do real Kubernetes-native Ingress routing. Since Compose's Traefik is now gone entirely, there's no second claimant for ports 80/443, so the original bug #2 doesn't recur.

What changed:
- `/etc/rancher/k3s/config.yaml`'s `disable: [traefik, servicelb]` was removed (now empty; a backup of the old content is at `/etc/rancher/k3s/config.yaml.bak-pre-traefik-cutover`), and k3s restarted. k3s's bundled Traefik + ServiceLB are enabled and own ports 80/443 (`kubectl get svc -n kube-system traefik` shows `EXTERNAL-IP 192.168.50.247`).
- Compose's `traefik` service block, container, and the old Docker-label-based routing (`traefik.enable`, etc. labels on `ollama`/`open-webui`/`pihole`) are **fully removed** from `docker-compose.yml`. `socket-proxy` is left running (nothing currently needs it, but it's harmless and might get used again later).
- The old `traefik-dynamic/` file-provider directory is deleted — no longer relevant.
- Routing now uses standard Kubernetes objects in the `homelab` namespace, in `/home/mint/containers/k8s/ingress.yaml`:
  - `metube` (already in k3s): plain `Ingress` → its existing Service.
  - `ollama`, `open-webui`, `pihole` (still on Compose/Podman): a selector-less `Service` + a matching `EndpointSlice` pointing at that service's **host-published port** on `192.168.50.247`, plus an `Ingress` for its hostname. This is the standard k8s pattern for routing cluster-internal traffic to something outside the cluster.
  - Pi-hole never had a host-published web-UI port before (only DNS on 53) — added `8089:80/tcp` to its Compose `ports:`.
- Things Ingress can't express use Traefik's own CRDs, in `/home/mint/containers/k8s/traefik-dashboard.yaml` (apply only after Traefik's chart — and its CRDs — actually exist):
  - A `Middleware` reproducing pihole's old redirect-to-`/admin`.
  - An `IngressRoute` + `Middleware` for `traefik.mint`, since the dashboard is the special `api@internal` service (not reachable via plain `Ingress`), including a root-path → `/dashboard/` redirect (the built-in auto-redirect is a feature of Traefik's separate internal admin port, not of what's exposed here — had to be reproduced explicitly).
  - `/home/mint/containers/k8s/traefik-config.yaml` is a `HelmChartConfig` enabling `--api.insecure=true` on k3s's Traefik, for parity with the old Compose Traefik dashboard (not a new weakening — matches prior behavior).
- **Adding a new k8s-native service going forward just means writing an `Ingress` object** — no more hand-editing Traefik config for each one.

### New host-level firewall fixes this required (2026-10-10)

k3s's own network traffic turned out to hit the *same class* of firewalld gap that bug #1 above was about, in two new spots. Both required **explicit user approval** since they're real security-loosening changes (confirmed with the user before applying, each time):

1. **Pod-to-pod traffic on k3s's own bridge (`cni0`) was being blocked.** `br_netfilter` forces even same-node pod-to-pod traffic through the host's firewall, and `cni0` was never assigned to any firewalld zone, so it fell through to the restrictive default (reject). This never surfaced before because nothing in the cluster needed real pod-to-pod routing until Traefik became an actual workload talking to other pods directly. **Fixed by adding `cni0` to the `trusted` firewalld zone** (`firewall-cmd --zone=trusted --change-interface=cni0 --permanent`), mirroring how `podman1` (Podman's bridge) was already trusted on this host. This means same-node container-to-container traffic — for *both* Podman and k3s now — bypasses firewall filtering entirely. Consistent with the existing precedent, but worth knowing if anything ever needs tighter isolation between pods.
2. **k3s pods reaching the Compose/Podman services' host-published ports was also blocked**, for the same underlying reason but a different direction (pod → host IP rather than pod → pod). Fixed narrowly instead: opened just the specific ports in the `FedoraServer` zone (`firewall-cmd --zone=FedoraServer --add-port={11434,3000,8089}/tcp --permanent`).

(A NodePort range `30080-32767/tcp` was also opened in `FedoraServer` during metube's earlier work, for a hairpin path that turned out not to be the real fix at the time — see below. It's no longer load-bearing now that Traefik runs inside the cluster, but was left open since it's harmless and `kubectl` NodePort debugging per the old todo item 6 still benefits from it.)

### Superseded finding from metube's earlier work

While metube's Ingress still went through *Compose's* Traefik (before this full cutover), the fix was "point Traefik at the Service's ClusterIP, not a NodePort/LAN-IP hairpin, because rootless Podman's `pasta` networking refuses to hairpin back to the host's own external IP on an unmapped port." **That finding is now moot for Traefik specifically** — Traefik runs inside k3s now, not under Podman, so it reaches pods and Services natively with no `pasta` involved. The `pasta` hairpin limitation would still apply to any *other* Podman container that needs to reach into the k3s cluster, though — keep that in mind if one comes up.

## Key facts gathered this session

- Host LAN IP: `192.168.50.247` (also the Pi-hole DNS server and now k3s Traefik's `EXTERNAL-IP`).
- Ollama, open-webui, and pihole's web UI are all still on Compose, reachable from k3s pods via their host-published ports (`11434`, `3000`, `8089` respectively) — see the EndpointSlice bridges above.
- k3s ships `local-path-provisioner` already installed — PVCs work out of the box, no extra provisioner setup needed.
- Nothing in the current Compose stack is wired to `postgres` yet (no service references it via env vars) — safe to stand it up fresh on k3s with no data migration needed, unless the user has manually put something in it.
- `open-webui`'s volume (`open-webui:/app/backend/data`) holds real state (chat history, accounts) — worth migrating if continuity matters, **when its compute actually moves to k8s** (routing is bridged now, but the app itself still runs on Compose).
- `metube`'s volume is just a download queue/history — low stakes, fine to start fresh (already done).
- Current Compose file: `/home/mint/containers/compose/docker-compose.yml`. `.env` (same directory) holds image tags and secrets (`POSTGRES_PASSWORD`, `MASTER_PASS`, etc.) — check it for current values before recreating equivalents in k8s Secrets.

## Already-started scaffolding

`/home/mint/containers/open-webui.yaml` and `/home/mint/containers/postgres-manifest.yaml` exist — auto-generated drafts from `podman generate kube`. **Treat them as rough starting points only, not something to apply as-is** (same caveats as metube's draft had: bare `Pod` not `Deployment`, `hostPort` instead of a Service, PVC claim names that don't exist yet). See `/home/mint/containers/k8s/metube.yaml` for what a properly-written version of this kind of manifest looks like for this cluster.

## Todo list — postgres / open-webui **compute** migration (routing is done; the apps themselves are still on Compose)

1. **Decide per-service whether to migrate data or start fresh** (Postgres: fresh is fine; open-webui: migrate if chat history matters).
2. **Write proper manifests** (Deployment + Service + PVC where needed) for `postgres` and `open-webui`, in the `homelab` namespace — using the generated drafts as rough references only.
3. **Point open-webui at ollama** via `http://192.168.50.247:11434` (ollama is staying on Compose permanently) and at the new Postgres Service if switching open-webui off its default SQLite backend.
4. **Migrate data** for anything chosen in step 1, before cutting traffic over (e.g. copy the Postgres dump and the open-webui volume contents into the new PVCs via a helper pod).
5. **Apply manifests, verify each service works** directly (pod IP / port-forward) before touching routing.
6. **Update `/home/mint/containers/k8s/ingress.yaml`**: once open-webui runs in k8s, replace its selector-less Service+EndpointSlice bridge with a plain Service pointing at the real pod selector (same pattern metube already uses) — just change the backend, the `Ingress` and hostname stay the same.
7. **Decommission the old Compose services** — remove `postgres`/`open-webui` blocks from `docker-compose.yml`, `docker compose up -d --remove-orphans` to apply, then clean up their old Podman volumes once confident the migration stuck.

**Status (2026-10-09): metube done** (k8s compute + routing, fully end-to-end, confirmed from a separate device on the LAN).
**Status (2026-10-10): ingress architecture cutover done.** All five hostnames (`ytmp3.mint`, `ai.mint`, `ollama.mint`, `pihole.mint`, `traefik.mint`) now route through k3s's own Traefik, confirmed from a separate device on the LAN. Postgres and open-webui's actual **compute** migration (items 1–7 above) is still pending — only their *routing* goes through k3s now, the apps themselves are unchanged on Compose.

## Things to double check before declaring success

- Confirm no `LoadBalancer`-type Services got created *unintentionally* anywhere in new manifests — one `LoadBalancer` (k3s's own `traefik` Service in `kube-system`) is now correct and expected; anything else shouldn't be.
- Confirm `netns-fix` is still in place after any `docker compose down/up` or k3s restart — still an ongoing workaround, not "finished and forgettable."
- Confirm `cni0` is still in the firewalld `trusted` zone, and `podman1` too, after any firewalld reload/restart or OS update: `firewall-cmd --zone=trusted --list-interfaces`.
- Confirm `/etc/rancher/k3s/config.yaml`'s disable list stays empty (or at least doesn't re-add `traefik`/`servicelb`) after any k3s upgrade — it would silently take down all five `*.mint` hostnames at once, not just the one being worked on.
- Test `*.mint` hostnames from a device other than the host itself (not just `curl 127.0.0.1` — loopback traffic bypasses firewall zone rules that real LAN traffic doesn't, which caused a real "worked for Claude, timed out for the user" mismatch earlier). This was followed for both the metube migration and this ingress cutover — keep doing it for anything touching routing.
