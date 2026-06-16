# syntax=docker/dockerfile:1
# File: docker/services/iceberg-rest/Dockerfile
#
# Self-built Iceberg REST catalog fixture — we do NOT pull the ready-made
# apache/iceberg-rest-fixture:1.8.1 image (512 MB). The only things pulled are a
# JDK builder base + a JRE-Alpine runtime base (both allowed by the 42-Inception
# rule) and the OFFICIAL Apache Iceberg 1.8.1 SOURCE release from archive.apache.org.
#
# WHY A SOURCE BUILD: the runnable fixture jar
# (iceberg-open-api-test-fixtures-runtime-*.jar) is NOT published to Maven
# Central or attached to the GitHub release — upstream's own Dockerfile copies it
# from a local Gradle build (`open-api/build/libs/…`). So the only honest "build
# it ourselves" path is to compile the shadow jar from the signed source tarball
# via `:iceberg-open-api:shadowJar`, then run it on a JRE-Alpine base — which is
# exactly what upstream does, minus pulling their image.
#
# Runtime mirrors upstream so docker-compose.yml keeps working unchanged:
#   jar → /usr/lib/iceberg-rest/iceberg-rest-adapter.jar   ·   port 8181
#   non-root iceberg user   ·   CATALOG_* env (compose overrides for MinIO/S3)
# NOTE: this Gradle build pulls a large dependency tree; if it cannot finish in a
# constrained local environment, build it in CI (the FROM/RUN below are the
# reproducible recipe). Pin via --build-arg ICEBERG_VERSION=1.8.1.

# ── builder: compile the shadow jar from the official source tarball ────────
FROM eclipse-temurin:17-jdk AS build
ARG ICEBERG_VERSION=1.8.1
ARG ICEBERG_SRC=https://archive.apache.org/dist/iceberg/apache-iceberg-${ICEBERG_VERSION}/apache-iceberg-${ICEBERG_VERSION}.tar.gz
WORKDIR /src
RUN set -eux; \
    apt-get update; apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fSL "${ICEBERG_SRC}" -o iceberg-src.tar.gz; \
    tar -xzf iceberg-src.tar.gz --strip-components=1; \
    rm iceberg-src.tar.gz
# Build only the open-api shadow jar (the runnable REST fixture). --no-daemon
# keeps the build container lean; offline deps are fetched by the Gradle wrapper.
RUN set -eux; \
    ./gradlew --no-daemon -x test -x javadoc :iceberg-open-api:shadowJar; \
    cp open-api/build/libs/iceberg-open-api-test-fixtures-runtime-*.jar \
       /iceberg-rest-adapter.jar

# ── runtime: Java 23 JRE on Alpine (shared with trino/debezium to dedup the
#    ~200 MB JRE layer; shadowJar is plain bytecode, runs on the newer JRE) ────
FROM eclipse-temurin:23-jre-alpine
RUN apk add --no-cache curl \
 && addgroup -g 1000 iceberg \
 && adduser -u 1000 -G iceberg -h /home/iceberg -D iceberg \
 && mkdir -p /usr/lib/iceberg-rest

COPY --from=build --chown=iceberg:iceberg /iceberg-rest-adapter.jar \
     /usr/lib/iceberg-rest/iceberg-rest-adapter.jar

# Defaults from the upstream fixture image (compose overrides CATALOG_* for the
# MinIO/S3 warehouse). In-memory SQLite JdbcCatalog by default.
ENV REST_PORT=8181 \
    CATALOG_CATALOG__IMPL=org.apache.iceberg.jdbc.JdbcCatalog \
    CATALOG_URI=jdbc:sqlite::memory: \
    CATALOG_JDBC_USER=user \
    CATALOG_JDBC_PASSWORD=password \
    LANG=en_US.UTF-8

WORKDIR /usr/lib/iceberg-rest
EXPOSE 8181
USER iceberg:iceberg

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD curl -fsS http://localhost:8181/v1/config >/dev/null || exit 1

CMD ["java", "-jar", "iceberg-rest-adapter.jar"]
