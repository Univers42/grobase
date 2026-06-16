# syntax=docker/dockerfile:1.7
# File: docker/services/vault/Dockerfile
FROM public.ecr.aws/hashicorp/vault:1.21

# Alpine-based image: add bash + jq for init script and prepare Vault data.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
  apk upgrade --no-cache \
  && apk add --no-cache bash jq \
  && mkdir -p /vault/data \
  && chown -R vault:vault /vault/data

COPY conf/vault.hcl    /vault/config/vault.hcl
COPY policies/          /vault/policies/
COPY scripts/           /vault/scripts/

RUN chmod +x /vault/scripts/*.sh 2>/dev/null || true

EXPOSE 8200
USER vault

HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=5 \
  CMD vault status -address=http://127.0.0.1:8200 2>/dev/null | grep -q 'Sealed.*false' || exit 1
