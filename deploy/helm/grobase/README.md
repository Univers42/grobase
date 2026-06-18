# grobase — PRODUCTION Helm chart (Track C / C3)

The **scale / HA** chart for a managed-cloud Grobase deployment. Hand-authored
(NOT generated). It is a **separate deploy target** from the generated
edition-selectable dev chart at [`../mini-baas`](../mini-baas) — installing
nothing from here changes nothing about the running compose stack or the dev
chart, so the live byte-parity baseline is untouched.

## What it renders

| Template | Produces |
|---|---|
| `workloads.yaml` | a **StatefulSet** per stateful plane (postgres, redis, with a `volumeClaimTemplate`) and a **Deployment** per stateless plane (data-plane-router-rust, tenant-control, adapter-registry-go, realtime, kong) |
| `hpa.yaml` | a **HorizontalPodAutoscaler** for every Deployment plane that sets `autoscaling.enabled` (CPU target; realtime is intentionally manual until cross-node presence lands — Track E2) |
| `service.yaml` | a ClusterIP Service per plane (headless for StatefulSets) so in-cluster DNS matches the compose service-name addressing |
| `ingress.yaml` | the managed front door → the `kong` plane Service |
| `networkpolicy.yaml` | a **deny-by-default** baseline (deny all ingress, allow only DNS + intra-release egress) plus one explicit per-plane ingress allow |
| `config.yaml` | the release ConfigMap (non-secret env) and, when Vault-CSI is off, an optional fallback Secret |
| `secretproviderclass.yaml` | a Vault-CSI `SecretProviderClass` when `vault.enabled=true` |

## Install

```sh
kubectl create namespace grobase

# Prod (defaults: HPA + Ingress + deny-by-default NetworkPolicy + Vault-CSI hook)
helm -n grobase install grobase .

# Inspect before applying
helm template grobase . | less
```

Override images without editing values:
`helm template grobase . --set global.imageTag=v1.2.3`.

## Dev / kind smoke (C3 gate path)

`values-dev.yaml` strips the prod-only edges so the chart installs on a laptop
cluster (no metrics-server, no NetworkPolicy-enforcing CNI, no CSI driver):

```sh
helm lint . -f values-dev.yaml
helm template grobase . -f values-dev.yaml | kubectl apply --dry-run=client -f -
# kind smoke (on a kind cluster):
helm -n grobase install grobase . -f values-dev.yaml
kubectl -n grobase port-forward svc/grobase-kong 8000
```

## Secrets

- **Prod**: set `vault.enabled=true`. Requires the [Secrets Store CSI driver]
  + the HashiCorp Vault provider installed in-cluster. A `SecretProviderClass`
  is rendered; every plane mounts it at `/vault/secrets`, and (with
  `vault.syncToK8sSecret=true`) the keys are projected into a K8s Secret the
  planes pick up via `envFrom`.
- **Dev / no-CSI clusters**: `env.secret.create=true` renders a plain Secret you
  fill with `--set env.secret.data.JWT_SECRET=…`.

## Honest translation limits

- **NetworkPolicy needs an enforcing CNI** (Calico/Cilium/etc.). On a CNI that
  ignores NetworkPolicy (kind's default kindnet) the policies render but do not
  isolate — hence `values-dev.yaml` turns them off.
- **HPA needs metrics-server.** Without it the HPA object exists but never
  scales.
- **Postgres `replicas` > 1 needs an operator** (Patroni / CloudNativePG). The
  in-chart StatefulSet is single-primary; true PG HA is **C4** (external managed
  PG: set `planes.postgres.enabled=false` and point the planes at it).
- **Probes are `exec` only** (mirrors the compose healthchecks); no HTTP/TCP
  probe translation yet.
- **No multi-region / cell pinning** here — that is **C5**.
- This chart has passed `helm lint` (default + `values-dev.yaml`) and renders to
  valid YAML; it has **not** been smoke-installed on a live kind cluster in this
  change (no cluster in the build env). The kind smoke is the **C3 gate**, run
  on-demand.

See the parent [`../../README.md`](../../README.md) for the deploy overview.
