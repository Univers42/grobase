# syntax=docker/dockerfile:1
# File: docker/services/loki/Dockerfile
#
# Self-built Loki: we download the upstream STATIC release ZIP (a binary
# artifact, NOT the grafana/loki image) from Grafana's official GitHub release
# and drop the `loki` binary onto Alpine. The loki binary is fully statically
# linked, so Alpine (musl) runs it directly — Alpine is the only base we pull
# (42-Inception rule). Tag matches the compose pin v3.0.0.
#
# compose mounts the config at /etc/loki/config.yaml, the store at /loki, probes
# /ready with wget, and passes `command: ["-config.file=/etc/loki/config.yaml"]`
# — that command supplies the args, so we set ENTRYPOINT to the binary and no
# default CMD flags (the compose command provides them).

# ── builder: fetch + unzip the static release binary ─────────────────────────
FROM alpine:3.21 AS build
ARG LOKI_VERSION=3.0.0
RUN apk add --no-cache wget unzip \
 && wget -q -O /tmp/loki.zip \
      "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip" \
 && unzip -o /tmp/loki.zip -d /tmp \
 && install -m 0755 /tmp/loki-linux-amd64 /out-loki \
 && /out-loki --version

# ── final: Alpine (busybox `wget` for the compose healthcheck) ───────────────
FROM alpine:3.21
RUN apk add --no-cache ca-certificates \
 && addgroup -g 1001 loki \
 && adduser -D -u 1001 -G loki -h /loki loki \
 && install -d -o loki -g loki /loki /etc/loki
COPY --from=build /out-loki /usr/bin/loki

EXPOSE 3100
USER 1001:1001
WORKDIR /loki

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD wget -qO- http://localhost:3100/ready >/dev/null || exit 1

# compose passes `command: ["-config.file=…"]` (the args), so ENTRYPOINT is the
# binary and there is no doubled `loki`.
ENTRYPOINT ["/usr/bin/loki"]
