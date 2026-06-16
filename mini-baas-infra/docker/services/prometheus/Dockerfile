# syntax=docker/dockerfile:1
# File: docker/services/prometheus/Dockerfile
#
# Self-built Prometheus: we download the upstream STATIC release TARBALL
# (a binary artifact, NOT the prom/prometheus image) from Prometheus' official
# GitHub release and drop the `prometheus` binary + console assets onto Alpine.
# The prometheus binary is fully statically linked, so Alpine (musl) runs it
# directly — Alpine is the only base we pull (42-Inception rule). Tag matches
# the compose pin v2.52.0.
#
# compose mounts the config at /etc/prometheus/prometheus.yml (+ rules/) and the
# TSDB at /prometheus, and probes /-/healthy with wget. compose sets NO explicit
# `command:`, so we reproduce the upstream image's DEFAULT flags here (config
# file + tsdb path + console libs/templates) as the overridable CMD.

# ── builder: fetch + extract the static release tarball ──────────────────────
FROM alpine:3.21 AS build
ARG PROM_VERSION=2.52.0
RUN apk add --no-cache wget tar \
 && wget -q -O /tmp/prom.tgz \
      "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
 && tar -xzf /tmp/prom.tgz -C /tmp \
 && mkdir -p /out/bin /out/share/prometheus \
 && cp /tmp/prometheus-${PROM_VERSION}.linux-amd64/prometheus /out/bin/prometheus \
 && cp /tmp/prometheus-${PROM_VERSION}.linux-amd64/promtool   /out/bin/promtool \
 && cp -r /tmp/prometheus-${PROM_VERSION}.linux-amd64/consoles          /out/share/prometheus/consoles \
 && cp -r /tmp/prometheus-${PROM_VERSION}.linux-amd64/console_libraries /out/share/prometheus/console_libraries \
 && /out/bin/prometheus --version

# ── final: Alpine (busybox `wget` for the compose healthcheck) ───────────────
FROM alpine:3.21
RUN apk add --no-cache ca-certificates \
 && addgroup -g 1001 prometheus \
 && adduser -D -u 1001 -G prometheus -h /prometheus prometheus \
 && install -d -o prometheus -g prometheus /prometheus /etc/prometheus
# Only the server binary ships — the compose service never invokes `promtool`,
# so dropping it saves ~130 MB. (Re-add the promtool COPY if a tooling shape
# ever needs it.)
COPY --from=build /out/bin/prometheus /bin/prometheus
COPY --from=build /out/share/prometheus /usr/share/prometheus

EXPOSE 9090
USER 1001:1001
WORKDIR /prometheus

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=5 \
  CMD wget -qO- http://localhost:9090/-/healthy >/dev/null || exit 1

# compose passes no `command:`, so these upstream-default flags run; if compose
# later adds a `command:`, it overrides CMD wholesale (ENTRYPOINT stays the bin).
ENTRYPOINT ["/bin/prometheus"]
CMD [ "--config.file=/etc/prometheus/prometheus.yml", \
      "--storage.tsdb.path=/prometheus", \
      "--web.console.libraries=/usr/share/prometheus/console_libraries", \
      "--web.console.templates=/usr/share/prometheus/consoles" ]
