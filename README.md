# otm-lab

Homelab infrastructure: a Podman Compose stack and a k3s cluster running side by
side on one host, fronted by Pi-hole DNS and k3s's own Traefik ingress.

## Layout

- `compose/` — the Podman Compose stack (`docker-compose.yml`, `.env`, Pi-hole's
  live data in `etc-pihole/`) plus `start.sh` to restart it.
- `k8s/` — Kubernetes manifests applied to the k3s cluster.
- `ollama/` — tooling for deploying custom Ollama models (`deploy.sh`), kept
  separate from the Compose stack's own `ollama` service definition.
- `docs/` — planning and migration notes.
- `metube-manifest.yaml`, `open-webui.yaml`, `postgres-manifest.yaml` — raw
  `podman generate kube` drafts, kept as rough starting-point references for
  services not yet (or only partially) migrated to k8s. Not meant to be applied
  as-is — see `docs/k3s-migration-handoff.md` for the caveats on each.

## Managing the Compose stack

From the repo root:

```
./compose/start.sh
```

or directly:

```
cd compose
docker compose up -d
```

(Compose auto-discovers `docker-compose.yml` and `.env` in the current
directory, so commands need to run from `compose/`, not the repo root.)

## Managing the k3s cluster

```
sudo k3s kubectl apply -f k8s/<file>.yaml
```

See `docs/k3s-migration-handoff.md` for the current architecture, what's
running where, and what's still pending migration.
