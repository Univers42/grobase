# syntax=docker/dockerfile:1
# File: docker/services/grafana/Dockerfile
#
# Self-built Grafana: Grafana is NOT a single binary (it has a frontend + bundled
# plugins), so we download the upstream official release TARBALL (a build
# artifact, NOT the grafana/grafana image) from Grafana's official release CDN
# and extract the parts we need — `bin/grafana` (197 MB, statically linked),
# `public/` (the frontend), `conf/` (defaults), and `plugins-bundled/` — onto
# Alpine. The grafana binary is statically linked, so Alpine (musl) runs it
# directly. Alpine is the only base we pull (42-Inception rule). Tag matches the
# compose pin 10.4.2.
#
# We DROP docs/, storybook/, npm-artifacts/, packaging/, tools/ (not needed at
# runtime) — that's the bulk of the slimming vs the fat upstream image.
#
# compose sets anonymous-auth via GF_AUTH_ANONYMOUS_* env, mounts provisioning
# at /etc/grafana/provisioning, stores data in /var/lib/grafana, probes
# /api/health with curl, and passes NO explicit `command:` — so we reproduce the
# upstream default (`grafana server` with the standard GF_PATHS_*).

# ── builder: fetch + extract only the runtime parts ──────────────────────────
FROM alpine:3.21 AS build
ARG GRAFANA_VERSION=10.4.2
RUN apk add --no-cache wget tar \
 && wget -q -O /tmp/grafana.tgz \
      "https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz" \
 && mkdir -p /out \
 && tar -xzf /tmp/grafana.tgz -C /tmp \
 && SRC="/tmp/grafana-v${GRAFANA_VERSION}" \
 && cp -r "$SRC/bin"             /out/bin \
 && cp -r "$SRC/public"          /out/public \
 && cp -r "$SRC/conf"            /out/conf \
 && cp -r "$SRC/plugins-bundled" /out/plugins-bundled \
 && /out/bin/grafana --version

# ── final: Alpine + ca-certs + curl (for the compose /api/health probe) ──────
FROM alpine:3.21
ENV GF_PATHS_HOME=/usr/share/grafana \
    GF_PATHS_DATA=/var/lib/grafana \
    GF_PATHS_LOGS=/var/log/grafana \
    GF_PATHS_PLUGINS=/var/lib/grafana/plugins \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    GF_PATHS_CONFIG=/etc/grafana/grafana.ini
# UID 472 is Grafana's conventional non-root user (matches the upstream image).
RUN apk add --no-cache ca-certificates curl bash \
 && addgroup -g 472 grafana \
 && adduser -D -u 472 -G grafana -h "$GF_PATHS_HOME" grafana \
 && install -d -o grafana -g grafana \
      "$GF_PATHS_DATA" "$GF_PATHS_DATA/plugins" "$GF_PATHS_LOGS" \
      /etc/grafana /etc/grafana/provisioning
COPY --from=build --chown=472:472 /out "$GF_PATHS_HOME"
# Seed a default grafana.ini from the shipped defaults so GF_PATHS_CONFIG exists
# even when the compose mount supplies none (env vars still override it).
RUN cp "$GF_PATHS_HOME/conf/defaults.ini" /etc/grafana/grafana.ini \
 && chown grafana:grafana /etc/grafana/grafana.ini

EXPOSE 3000
USER 472:472
WORKDIR /usr/share/grafana

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD curl -fsS http://localhost:3000/api/health >/dev/null || exit 1

# compose passes no `command:`, so the upstream default `grafana server` runs
# (homepath/config come from the GF_PATHS_* env above). A compose `command:`
# would override CMD wholesale; ENTRYPOINT stays the grafana binary.
ENTRYPOINT ["/usr/share/grafana/bin/grafana"]
CMD ["server"]
