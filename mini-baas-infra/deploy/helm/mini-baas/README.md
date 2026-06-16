# mini-baas Helm chart (generated)

Generated from the edition manifest — see [`../../README.md`](../../README.md). Do
not hand-edit `values.yaml` or `values-<edition>.yaml`; run `make deploy-gen`.

## Install an edition

```sh
# create env + secrets (K8s equivalent of compose env_file: [.env])
kubectl create namespace mini-baas
kubectl -n mini-baas create configmap mb-env       --from-env-file=../../../.env
kubectl -n mini-baas create secret  generic mb-secrets --from-env-file=../../../.env.secret

# render or install a known-good edition
helm template mb . -f values-prod.yaml          # inspect
helm -n mini-baas install mb . -f values-prod.yaml
```

Release name `mb` ⇒ Deployments/Services are named `mb-<service>`, and in-cluster
DNS is `http://mb-<service>:<port>` (matches the compose service-name addressing
the planes already use, e.g. `mb-adapter-registry-go:3021`).

## Values shape

```yaml
global: { imageRegistry, imageTag, imagePullPolicy }
edition: <name>            # informational label
services:
  <service>:
    enabled: bool          # the edition overlay flips this
    image: <ref>           # compose image, or ${DEPLOY_REGISTRY}/mini-baas-<svc>:<tag>
    replicas: 1
    ports: [<containerPort>...]
    resources: { limits/requests }   # from compose mem_limit/cpus
    probe: { exec, initialDelaySeconds, periodSeconds, timeoutSeconds, failureThreshold }
```

Override images without regenerating: `helm template … --set global.imageTag=v1.2.3`
(applies to built services that fall back to the registry convention). Public
images pinned in compose are rendered verbatim.

See [`../../README.md`](../../README.md) for the honest list of translation limits
(env/secrets, ingress, PVCs, probe fidelity).
