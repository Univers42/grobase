# syntax=docker/dockerfile:1
# File: docker/services/debezium/Dockerfile
#
# Self-built Debezium Server from the OFFICIAL distribution tarball on a
# JRE-Alpine base — we do NOT pull the ready-made quay.io/debezium/server:3.0
# image (1.06 GB). The only things pulled are the JRE base (allowed by the
# 42-Inception rule) and the signed dist tarball from Maven Central.
#
# Debezium Server 3.0 runs on Java 11+; we use the Java 21 LTS JRE on Alpine.
# The container layout mirrors upstream so docker-compose.yml's mount keeps
# working unchanged:
#   install/SERVER_HOME → /debezium   ·   config → /debezium/config
# compose mounts /debezium/config/application.properties over our placeholder,
# and run.sh (shipped in the tarball) reads it from there. CMD is /debezium/run.sh.

# ── builder: fetch + extract the official Debezium Server dist tarball ───────
FROM alpine:3.21 AS fetch
ARG DEBEZIUM_VERSION=3.0.0.Final
ARG DEBEZIUM_TARBALL=https://repo1.maven.org/maven2/io/debezium/debezium-server-dist/${DEBEZIUM_VERSION}/debezium-server-dist-${DEBEZIUM_VERSION}.tar.gz
RUN apk add --no-cache curl tar gzip
WORKDIR /build
RUN curl -fSL "${DEBEZIUM_TARBALL}" -o debezium.tar.gz \
 && mkdir -p /debezium \
 && tar -xzf debezium.tar.gz -C /debezium --strip-components=1 \
 && rm debezium.tar.gz \
 && mkdir -p /debezium/config

# ── runtime: Java 23 JRE on Alpine (shared with trino/iceberg to dedup the
#    ~200 MB JRE layer; Debezium Server 3.0 runs on Java 11+, validated on 23) ─
FROM eclipse-temurin:23-jre-alpine

# bash → run.sh; curl → the /q/health healthcheck.
RUN apk add --no-cache bash curl \
 && addgroup -g 1000 debezium \
 && adduser -u 1000 -G debezium -h /debezium -D debezium

COPY --from=fetch --chown=debezium:debezium /debezium /debezium

WORKDIR /debezium
EXPOSE 8080
USER debezium

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -fsS http://localhost:8080/q/health >/dev/null || exit 1

CMD ["/debezium/run.sh"]
