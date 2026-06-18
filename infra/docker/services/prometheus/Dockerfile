# syntax=docker/dockerfile:1
# File: docker/services/prometheus/Dockerfile
#
# Self-built Prometheus: we download the upstream STATIC release TARBALL
# (a binary artifact, NOT the prom/prometheus image) from Prometheus' official
# GitHub release and drop the `prometheus` binary + console assets onto SCRATCH.
# The prometheus binary is fully statically linked (verified: `ldd` reports
# "Not a valid dynamic program"), so it needs no libc/loader at all — scratch
# runs it directly (nano philosophy; drops the ~8 MB Alpine layer + its shell/
# apk attack surface). Tag matches the compose pin v2.52.0.
#
# Why scratch is safe here:
#   • static binary → no /lib, no loader, no shell needed at runtime;
#   • no outbound TLS from the server itself → no ca-certificates bundle needed
#     (it scrapes plain-HTTP targets in this stack); the alpine final used to
#     install ca-certificates "just in case" — unused, so dropped;
#   • the compose healthcheck is `wget -qO- http://localhost:9090/-/healthy`,
#     which scratch can't satisfy with a shell, so we ship ONE static busybox
#     (same pattern as docker/services/postgrest/Dockerfile) to provide `wget`;
#   • scratch has no /etc/passwd, so USER must be numeric → `USER 1001:1001`.
#
# compose mounts the config at /etc/prometheus/prometheus.yml (+ rules/) and the
# TSDB at /prometheus, and probes /-/healthy with wget. compose sets NO explicit
# `command:`, so we reproduce the upstream image's DEFAULT flags here (config
# file + tsdb path + console libs/templates) as the overridable CMD.

# ── builder: fetch + extract the static release tarball + a static busybox ───
FROM alpine:3.21 AS build
ARG PROM_VERSION=2.52.0
RUN apk add --no-cache wget tar busybox-static \
 && wget -q -O /tmp/prom.tgz \
      "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
 && tar -xzf /tmp/prom.tgz -C /tmp \
 && mkdir -p /out/bin /out/share/prometheus \
 && cp /tmp/prometheus-${PROM_VERSION}.linux-amd64/prometheus /out/bin/prometheus \
 && cp /tmp/prometheus-${PROM_VERSION}.linux-amd64/promtool   /out/bin/promtool \
 && cp -r /tmp/prometheus-${PROM_VERSION}.linux-amd64/consoles          /out/share/prometheus/consoles \
 && cp -r /tmp/prometheus-${PROM_VERSION}.linux-amd64/console_libraries /out/share/prometheus/console_libraries \
 && /out/bin/prometheus --version

# ── final: SCRATCH + static busybox (for the compose wget healthcheck) ───────
FROM scratch
# Only the server binary ships — the compose service never invokes `promtool`,
# so dropping it saves ~130 MB. (Re-add the promtool COPY if a tooling shape
# ever needs it.)
COPY --from=build /out/bin/prometheus /bin/prometheus
COPY --from=build /out/share/prometheus /usr/share/prometheus
COPY --from=build /bin/busybox.static /bin/busybox

EXPOSE 9090
# scratch has no /etc/passwd, so the non-root user must be a numeric uid:gid.
USER 1001:1001
WORKDIR /prometheus

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=5 \
  CMD ["/bin/busybox", "wget", "-qO-", "http://localhost:9090/-/healthy"]

# compose passes no `command:`, so these upstream-default flags run; if compose
# later adds a `command:`, it overrides CMD wholesale (ENTRYPOINT stays the bin).
ENTRYPOINT ["/bin/prometheus"]
CMD [ "--config.file=/etc/prometheus/prometheus.yml", \
      "--storage.tsdb.path=/prometheus", \
      "--web.console.libraries=/usr/share/prometheus/console_libraries", \
      "--web.console.templates=/usr/share/prometheus/consoles" ]
