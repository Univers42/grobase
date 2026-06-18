# deploy/ — non-Compose packaging (G11)

The BaaS's value is *layer selection*: pick an edition, swap a plane. That choice
lives in **one** place — the Makefile MANIFEST (planes → compose profiles,
editions → planes) plus `docker-compose.yml` (per-service facts). This directory
makes the **same manifest compile to more than one runtime**, so K8s editions
match Compose editions by construction instead of being hand-maintained in parallel.

Everything here is **generated** — never hand-edit. Regenerate after changing an
edition (Makefile) or a service (compose):

```sh
make deploy-gen          # → edition-manifest.yaml, helm values, kustomize overlays
make deploy-template EDITION=prod   # render that edition's K8s manifests via Helm
```

## Layout

| Path | What | Source |
|---|---|---|
| `edition-manifest.yaml` | resolved planes→profiles, editions→planes→profiles→services | Makefile + compose |
| `helm/mini-baas/` | umbrella chart; generic templates render Deployment+Service per enabled service | static templates + generated values |
| `helm/mini-baas/values.yaml` | service catalog (image/ports/resources/probe), core enabled | generated from compose |
| `helm/mini-baas/values-<edition>.yaml` | overlay flipping `enabled` for that edition | generated from manifest |
| `kustomize/overlays/<edition>/edition.yaml` | manifest-driven service selection for GitOps/kustomize consumers | generated from manifest |

## How an edition is resolved (identical to `docker compose --profile`)

A service is in an edition iff it is **profile-less (core, always on)** *or* its
compose `profiles:` intersect the edition's profiles. The generator computes the
edition's profiles from the Makefile's `EDITION_<name>` plane list mapped through
`PROFILES_<plane>`. So `helm template … -f values-query.yaml` enables exactly the
services `make up EDITION=query` starts. The `m21-deploy-packaging` gate asserts
this stays true (and that the generated tree is up to date with its sources).

## Honest limitations (this is packaging scaffolding, not a turnkey prod deploy)

- **Env/secrets**: containers source env from an optional ConfigMap
  `<release>-env` and Secret `<release>-secrets` (the K8s equivalent of compose
  `env_file: [.env]`). You must create those — service-to-service DNS, DSNs and
  tokens are not baked into the chart. See the chart NOTES.
- **Images**: services with a public `image:` in compose use it verbatim; locally
  *built* services get `${DEPLOY_REGISTRY}/mini-baas-<service>:${DEPLOY_TAG}` —
  you must build & push those images for the chart to pull.
- **Probes**: compose healthchecks translate to exec readiness/liveness probes
  best-effort (CMD / CMD-SHELL). HTTP healthchecks become exec probes too; review
  before prod.
- **Networking/Ingress/PVCs**: not generated. ClusterIP Services give in-cluster
  DNS matching compose service names; add Ingress + PersistentVolumeClaims per
  your cluster. Compose `depends_on` ordering is replaced by K8s probe-based
  readiness (init ordering is not reproduced).

Compose remains the first-class dev/local runtime; this tree is the portability seam.
