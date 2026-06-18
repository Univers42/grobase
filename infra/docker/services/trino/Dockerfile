# syntax=docker/dockerfile:1
# File: docker/services/trino/Dockerfile
#
# Self-built Trino from the OFFICIAL server tarball on a JRE-Alpine base — we do
# NOT pull the ready-made trinodb/trino:467 image (1.49 GB). The only thing
# pulled is the JRE base (allowed by the 42-Inception rule) and the signed
# release tarball from Maven Central.
#
# Trino 467 REQUIRES Java 23 (Java 21/22 are rejected by its version check), so
# the runtime base is eclipse-temurin:23-jre-alpine. The container layout mirrors
# upstream exactly so docker-compose.yml's mounts keep working unchanged:
#   install → /usr/lib/trino   ·   config → /etc/trino   ·   data → /data/trino
# compose mounts /etc/trino/config.properties and /etc/trino/catalog/*.properties
# over the defaults baked here; node.properties + jvm.config stay from the image.
# Launcher: bin/run-trino (vendored) → bin/launcher (the tarball's Python script,
# hence python3 in the runtime).

# ── builder: fetch + extract the official Trino server tarball ──────────────
FROM alpine:3.21 AS fetch
ARG TRINO_VERSION=467
ARG TRINO_TARBALL=https://repo1.maven.org/maven2/io/trino/trino-server/${TRINO_VERSION}/trino-server-${TRINO_VERSION}.tar.gz
RUN apk add --no-cache curl tar gzip
WORKDIR /build
RUN curl -fSL "${TRINO_TARBALL}" -o trino.tar.gz \
 && mkdir -p /opt/trino \
 && tar -xzf trino.tar.gz -C /opt/trino --strip-components=1 \
 && rm trino.tar.gz \
 # The CLI is not needed inside the server image; drop the bundled JDK the
 # tarball does NOT ship (it expects an external JRE), keep bin/ (launcher +
 # libjvmkill.so) and the plugin/lib trees.
 && rm -rf /opt/trino/bin/*.jdk 2>/dev/null || true

# ── runtime: Java 23 JRE on Alpine ──────────────────────────────────────────
FROM eclipse-temurin:23-jre-alpine
ARG TRINO_VERSION=467

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
