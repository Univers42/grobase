# syntax=docker/dockerfile:1
# File: docker/services/trino/Dockerfile
#
# Self-built Trino from the OFFICIAL server tarball on a JRE-Alpine base — we do
# NOT pull the ready-made trinodb/trino image (1.49 GB). The only thing
# pulled is the JRE base (allowed by the 42-Inception rule) and the signed
# release tarball from Maven Central.
#
# Trino REQUIRES an exact Java generation (its own version check rejects the
# others by name: 8, 11, 17, 21 and 24 "do not work"), so the runtime base has
# to move with TRINO_VERSION. 483 wants Java 25. The container layout mirrors
# upstream exactly so docker-compose.yml's mounts keep working unchanged:
#   install → /usr/lib/trino   ·   config → /etc/trino   ·   data → /data/trino
# compose mounts /etc/trino/config.properties and /etc/trino/catalog/*.properties
# over the defaults baked here; node.properties + jvm.config stay from the image.
# Launcher: bin/run-trino (vendored) → bin/launcher (the tarball's Python script,
# hence python3 in the runtime).

# ── builder: fetch + extract the official Trino server tarball ──────────────
FROM alpine:3.21 AS fetch
# The tarball comes from the GitHub release, which is where Maven Central has
# been REDIRECTING this artifact to anyway -- and the redirect is why the
# `Build (infra) trino` job on main broke: Trino prunes the release assets of
# older versions, so 467's trino-server-467.tar.gz 404s at the end of that
# redirect while the Maven directory listing still advertises it. Pointing at
# the real host makes that failure legible the day it happens again; the
# version has to be one whose asset still exists (483 as of 2026-09-21).
ARG TRINO_VERSION=483
ARG TRINO_TARBALL=https://github.com/trinodb/trino/releases/download/${TRINO_VERSION}/trino-server-${TRINO_VERSION}.tar.gz
RUN apk add --no-cache curl tar gzip
WORKDIR /build
RUN curl -fSL "${TRINO_TARBALL}" -o trino.tar.gz \
 && mkdir -p /opt/trino \
 && tar -xzf trino.tar.gz -C /opt/trino --strip-components=1 \
 && rm trino.tar.gz \
 # The CLI is not needed inside the server image; drop the bundled JDK the
 # tarball does NOT ship (it expects an external JRE), keep bin/ (launcher +
 # libjvmkill.so) and the plugin/lib trees. No `|| true`: it bound to the
 # whole chain, so a 404 or a disk-full tar built green with no server.
 && rm -rf /opt/trino/bin/*.jdk \
 && test -x /opt/trino/bin/launcher

# ── runtime: Java 23 JRE on Alpine ──────────────────────────────────────────
FROM eclipse-temurin:25-jre-alpine
ARG TRINO_VERSION=483

# python3 → required by bin/launcher; bash → run-trino; curl → healthcheck.
RUN apk add --no-cache bash python3 curl \
 && addgroup -g 1000 trino \
 && adduser -u 1000 -G trino -h /home/trino -D trino \
 && mkdir -p /usr/lib/trino /etc/trino/catalog /data/trino \
 && chown -R trino:trino /data/trino

COPY --from=fetch --chown=trino:trino /opt/trino /usr/lib/trino
COPY --chown=trino:trino etc/node.properties /etc/trino/node.properties
COPY --chown=trino:trino etc/jvm.config      /etc/trino/jvm.config
# Default standalone config.properties (compose overrides this via a bind mount).
COPY --chown=trino:trino conf/config.properties /etc/trino/config.properties
COPY --chmod=0755 bin/run-trino /usr/lib/trino/bin/run-trino

EXPOSE 8080
USER trino
WORKDIR /usr/lib/trino

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://localhost:8080/v1/info >/dev/null || exit 1

CMD ["/usr/lib/trino/bin/run-trino"]
