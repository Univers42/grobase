# syntax=docker/dockerfile:1
# File: docker/services/promtail/Dockerfile
#
# Self-built Promtail: we download the upstream STATIC release ZIP (a binary
# artifact, NOT the grafana/promtail image) from Grafana's official GitHub
# release and drop the `promtail` binary onto Alpine. Tag matches the compose
# pin v3.0.0.
#
# Base note: the official promtail linux build is glibc-linked (interpreter
# /lib64/ld-linux-x86-64.so.2 — needs libc/libresolv/libpthread/libdl), so plain
# Alpine/musl can't run it. We add `gcompat` (Alpine's musl→glibc shim, ~a few
# hundred KB) — far slimmer than pulling a whole Debian base — and it's enough
# for this Go binary's libc/libresolv needs. Alpine is the only base we pull
# (42-Inception rule).
#
# RUNTIME / privilege note: promtail tails ROOT-owned host log files
# (/var/lib/docker/containers, bind-mounted ro) and reads /var/run/docker.sock.
# The compose service sets no `user:`, matching the upstream image which runs as
# root — so this image deliberately runs as root too. Dropping to a non-root UID
# would EPERM on those root-owned container logs and silently lose log streams.
#
# compose passes `command: ["-config.file=/etc/promtail/config.yaml"]` (the
# args), so ENTRYPOINT is the binary and there is no doubled `promtail`. There
# is NO healthcheck BY DESIGN (push-only agent; Loki's /ready covers the sink).

# ── builder: fetch + unzip the release binary ────────────────────────────────
FROM alpine:3.21 AS build
ARG PROMTAIL_VERSION=3.0.0
RUN apk add --no-cache wget unzip \
 && wget -q -O /tmp/promtail.zip \
      "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip" \
 && unzip -o /tmp/promtail.zip -d /tmp \
 && install -m 0755 /tmp/promtail-linux-amd64 /out-promtail

# ── final: Alpine + gcompat (glibc shim) + CA certs ──────────────────────────
FROM alpine:3.21
RUN apk add --no-cache ca-certificates gcompat \
 && install -d /etc/promtail /tmp/positions
COPY --from=build /out-promtail /usr/bin/promtail
# Smoke the glibc-shim load path at build time so a broken base fails the build.
RUN /usr/bin/promtail --version

# Runs as root by design (see header) to read root-owned host container logs.
ENTRYPOINT ["/usr/bin/promtail"]
