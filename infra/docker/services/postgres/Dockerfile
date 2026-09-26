# syntax=docker/dockerfile:1.7
# File: docker/services/postgres/Dockerfile
# PostgreSQL 16 Alpine with pg_net extension (required by GoTrue webhooks / Supabase).

# Docker official images; mirror.gcr.io serves Docker Hub's digests without
# public.ecr.aws's anonymous data cap (public.ecr.aws/docker/library works too).
ARG BASE_REGISTRY=mirror.gcr.io/library
FROM ${BASE_REGISTRY}/postgres:16-alpine AS pg_net_builder

ARG PG_NET_VERSION=0.14.0
ARG MYSQL_FDW_VERSION=2_9_2
ARG MONGO_FDW_VERSION=5_5_1
ARG TDS_FDW_VERSION=2_0_4
ARG ORACLE_FDW_VERSION=2_7_0
ARG REDIS_FDW_VERSION=1_0_0
ARG CLICKHOUSE_FDW_VERSION=1_5_0
ARG MULTICORN_VERSION=2_5_0
ARG SQLITE_FDW_VERSION=2_5_0
ADD https://github.com/supabase/pg_net/archive/refs/tags/v${PG_NET_VERSION}.tar.gz /tmp/pg_net.tar.gz

# Install build dependencies for pg_net
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --no-cache --virtual .pg-net-build-deps \
    build-base \
    ca-certificates \
    curl-dev \
  && tar -xzf /tmp/pg_net.tar.gz -C /tmp \
  && mv "/tmp/pg_net-${PG_NET_VERSION}" /tmp/pg_net
WORKDIR /tmp/pg_net
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    sed -i \
    -e 's/CURLOPT_POST, 1)/CURLOPT_POST, 1L)/' \
    -e 's/CURLOPT_POSTFIELDSIZE, 0)/CURLOPT_POSTFIELDSIZE, 0L)/' \
    -e 's/CURLOPT_TIMEOUT_MS, cdata->timeout_milliseconds)/CURLOPT_TIMEOUT_MS, (long)cdata->timeout_milliseconds)/' \
    -e 's/CURLOPT_FOLLOWLOCATION, true)/CURLOPT_FOLLOWLOCATION, 1L)/' \
    src/core.c \
  && sed -i '1i#define CURL_DISABLE_TYPECHECK 1' src/core.c src/event.h src/errors.c src/util.c src/worker.c \
  && make with_llvm=no \
  && make install with_llvm=no \
  && apk del .pg-net-build-deps \
  && rm -rf /tmp/pg_net /tmp/pg_net.tar.gz /var/cache/apk/*

# pgvector — built here from source (musl-OK C extension) so the SERVER carries the
# `vector` type/ops. This is what lets db-bootstrap drop the 438 MB pgvector image
# for a 13 MB postgres-client: the extension lives in the engine, not the bootstrap.
ARG PGVECTOR_VERSION=0.8.0
ADD https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz /tmp/pgvector.tar.gz
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --no-cache --virtual .pgvector-build-deps build-base \
  && tar -xzf /tmp/pgvector.tar.gz -C /tmp
WORKDIR /tmp/pgvector-${PGVECTOR_VERSION}
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    make with_llvm=no \
  && make install with_llvm=no \
  && apk del .pgvector-build-deps \
  && rm -rf /tmp/pgvector* /var/cache/apk/*

FROM ${BASE_REGISTRY}/postgres:16-alpine AS postgres_runtime

ARG MYSQL_FDW_VERSION=2_9_2
ARG MONGO_FDW_VERSION=5_5_1
ARG TDS_FDW_VERSION=2_0_4
ARG ORACLE_FDW_VERSION=2_7_0
ARG REDIS_FDW_VERSION=1_0_0
ARG CLICKHOUSE_FDW_VERSION=1_5_0
ARG MULTICORN_VERSION=2_5_0
ARG SQLITE_FDW_VERSION=2_5_0
# Re-declared here: ARGs are stage-scoped and the manifest below prints them.
ARG PG_NET_VERSION=0.14.0
ARG PGVECTOR_VERSION=0.8.0

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
  apk upgrade --no-cache \
  && apk add --no-cache ca-certificates libcurl su-exec \
  && printf '%s\n' '#!/bin/sh' 'exec /sbin/su-exec "$@"' > /usr/local/bin/gosu \
  && chmod 0755 /usr/local/bin/gosu

# The FDW manifest states what this image actually ships: the FDW extensions are NOT
# compiled in (migration 020's fdws_bootstrap_available() reports what the server
# can load); the versions are the ones a bootstrap would target. It used to print
# placeholder "sha256:…-pinned-by-mini-baas" strings that verified nothing.
RUN mkdir -p /usr/local/share/mini-baas/fdw \
  && { \
    echo "# extension  target-version  status"; \
    echo "mysql_fdw ${MYSQL_FDW_VERSION} not-built"; \
    echo "mongo_fdw ${MONGO_FDW_VERSION} not-built"; \
    echo "tds_fdw ${TDS_FDW_VERSION} not-built"; \
    echo "oracle_fdw ${ORACLE_FDW_VERSION} not-built"; \
    echo "redis_fdw ${REDIS_FDW_VERSION} not-built"; \
    echo "clickhousedb_fdw ${CLICKHOUSE_FDW_VERSION} not-built"; \
    echo "multicorn ${MULTICORN_VERSION} not-built"; \
    echo "file_fdw built-in postgresql-16"; \
    echo "sqlite_fdw ${SQLITE_FDW_VERSION} not-built"; \
    echo "pg_net ${PG_NET_VERSION} built-in"; \
    echo "vector ${PGVECTOR_VERSION} built-in"; \
    echo "pg_graphql (see pg_graphql_builder) built-in"; \
  } > /usr/local/share/mini-baas/fdw/manifest.txt

COPY --from=pg_net_builder /usr/local/lib/postgresql/pg_net.so /usr/local/lib/postgresql/
COPY --from=pg_net_builder /usr/local/share/postgresql/extension/pg_net* /usr/local/share/postgresql/extension/
COPY --from=pg_net_builder /usr/local/lib/postgresql/vector.so /usr/local/lib/postgresql/
COPY --from=pg_net_builder /usr/local/share/postgresql/extension/vector* /usr/local/share/postgresql/extension/

EXPOSE 5432

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -h 127.0.0.1 || exit 1

# nosemgrep: dockerfile.security.missing-user.missing-user -- the official postgres
# entrypoint starts as root to initialize/chown PGDATA, then drops to the unprivileged
# `postgres` user via gosu; an explicit USER would break initdb.
# ── pg_graphql (supabase) — GraphQL over the schema PostgREST already serves ──
# supabase ships only glibc .deb packages; this Alpine server compiles the
# extension with pgrx against its own pg_config (same clang/llvm as the server:
# clang-21). rustfmt is what pgrx's bindgen shells out to. Kong's /graphql/v1
# route and migration 087 (graphql_public.graphql()) are what serve it.
FROM postgres_runtime AS pg_graphql_builder
ARG PG_GRAPHQL_VERSION=v1.6.2
RUN apk add --no-cache rust cargo rustfmt git clang21 clang21-dev llvm21-dev build-base \
      openssl-dev musl-dev pkgconf readline-dev zlib-dev bison flex perl icu-dev \
      libxml2-dev libxslt-dev linux-headers
ENV CARGO_BUILD_JOBS=4 \
    RUSTFLAGS="-C target-feature=-crt-static" \
    CARGO_HOME=/root/.cargo \
    PATH=/root/.cargo/bin:/usr/local/bin:/usr/bin:/bin
RUN git clone --depth 1 -b ${PG_GRAPHQL_VERSION} https://github.com/supabase/pg_graphql /tmp/pg_graphql \
 && v=$(grep -m1 -E '^pgrx\s*=' /tmp/pg_graphql/Cargo.toml | sed -E 's/.*"=?([0-9][0-9.]*)".*/\1/') \
 && cargo install cargo-pgrx --version "$v" --locked \
 && cargo pgrx init --pg16 "$(which pg_config)" \
 && cd /tmp/pg_graphql \
 && cargo pgrx install --release --pg-config "$(which pg_config)" \
 && test -f /usr/local/lib/postgresql/pg_graphql.so

FROM scratch

COPY --from=postgres_runtime / /
COPY --from=pg_graphql_builder /usr/local/lib/postgresql/pg_graphql.so /usr/local/lib/postgresql/
COPY --from=pg_graphql_builder /usr/local/share/postgresql/extension/pg_graphql* /usr/local/share/postgresql/extension/

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  GOSU_VERSION=1.19 \
  LANG=en_US.utf8 \
  PG_MAJOR=16 \
  PG_VERSION=16.14 \
  PG_SHA256=f6d077142737920858ce958ccdb75c6ee137a63b5b0853c70693d401ac7e3471 \
  DOCKER_PG_LLVM_DEPS="llvm19-dev \t\tclang19" \
  PGDATA=/var/lib/postgresql/data

EXPOSE 5432
VOLUME ["/var/lib/postgresql/data"]

# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint -- gosu privilege-drop, see FROM
ENTRYPOINT ["docker-entrypoint.sh"]
# nosemgrep: dockerfile.security.missing-user.missing-user -- gosu privilege-drop, see FROM
CMD ["postgres"]

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -h 127.0.0.1 || exit 1
