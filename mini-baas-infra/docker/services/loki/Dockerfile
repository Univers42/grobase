# syntax=docker/dockerfile:1
# File: docker/services/loki/Dockerfile
#
# Self-built Loki: we download the upstream STATIC release ZIP (a binary
# artifact, NOT the grafana/loki image) from Grafana's official GitHub release
# and drop the `loki` binary onto SCRATCH. The loki binary is fully statically
# linked (verified: `ldd` reports "Not a valid dynamic program"), so it needs no
# libc/loader at all — scratch runs it directly (nano philosophy; drops the
# ~8 MB Alpine layer + its shell/apk attack surface). Tag matches the compose
# pin v3.0.0.
#
# Why scratch is safe here:
#   • static binary → no /lib, no loader, no shell needed at runtime;
#   • Loki ingests over its HTTP API and writes to its local filesystem store in
#     this single-binary edition → no outbound TLS, so no ca-certificates bundle
#     is needed (the alpine final installed it unused, so it's dropped);
#   • the compose healthcheck is `wget -qO- http://localhost:3100/ready`, which
#     scratch can't satisfy with a shell, so we ship ONE static busybox (same
#     pattern as docker/services/postgrest/Dockerfile) to provide `wget`;
#   • scratch has no /etc/passwd, so USER must be numeric → `USER 1001:1001`.
#
# compose mounts the config at /etc/loki/config.yaml, the store at /loki, probes
# /ready with wget, and passes `command: ["-config.file=/etc/loki/config.yaml"]`
# — that command supplies the args, so we set ENTRYPOINT to the binary and no
# default CMD flags (the compose command provides them).

# ── builder: fetch + unzip the static release binary + a static busybox ──────
FROM alpine:3.21 AS build
ARG LOKI_VERSION=3.0.0
RUN apk add --no-cache wget unzip busybox-static \
 && wget -q -O /tmp/loki.zip \
      "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip" \
 && unzip -o /tmp/loki.zip -d /tmp \
 && install -m 0755 /tmp/loki-linux-amd64 /out-loki \
 && /out-loki --version

# ── final: SCRATCH + static busybox (for the compose wget healthcheck) ───────
FROM scratch
COPY --from=build /out-loki /usr/bin/loki
COPY --from=build /bin/busybox.static /bin/busybox

EXPOSE 3100
# scratch has no /etc/passwd, so the non-root user must be a numeric uid:gid.
USER 1001:1001
WORKDIR /loki

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD ["/bin/busybox", "wget", "-qO-", "http://localhost:3100/ready"]

# compose passes `command: ["-config.file=…"]` (the args), so ENTRYPOINT is the
# binary and there is no doubled `loki`.
ENTRYPOINT ["/usr/bin/loki"]
