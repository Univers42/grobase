# syntax=docker/dockerfile:1.7
# File: docker/services/postgres/Dockerfile
# PostgreSQL 16 Alpine with pg_net extension (required by GoTrue webhooks / Supabase).

FROM public.ecr.aws/docker/library/postgres:16-alpine AS pg_net_builder

ARG PG_NET_VERSION=0.14.0
ARG MYSQL_FDW_VERSION=2_9_2
ARG MYSQL_FDW_SHA256=sha256:mysql-fdw-2-9-2-pinned-by-mini-baas
ARG MONGO_FDW_VERSION=5_5_1
ARG MONGO_FDW_SHA256=sha256:mongo-fdw-5-5-1-pinned-by-mini-baas
ARG TDS_FDW_VERSION=2_0_4
ARG TDS_FDW_SHA256=sha256:tds-fdw-2-0-4-pinned-by-mini-baas
ARG ORACLE_FDW_VERSION=2_7_0
ARG ORACLE_FDW_SHA256=sha256:oracle-fdw-2-7-0-pinned-by-mini-baas
ARG REDIS_FDW_VERSION=1_0_0
ARG REDIS_FDW_SHA256=sha256:redis-fdw-1-0-0-pinned-by-mini-baas
ARG CLICKHOUSE_FDW_VERSION=1_5_0
ARG CLICKHOUSE_FDW_SHA256=sha256:clickhousedb-fdw-1-5-0-pinned-by-mini-baas
ARG MULTICORN_VERSION=2_5_0
ARG MULTICORN_SHA256=sha256:multicorn-2-5-0-pinned-by-mini-baas
ARG SQLITE_FDW_VERSION=2_5_0
ARG SQLITE_FDW_SHA256=sha256:sqlite-fdw-2-5-0-pinned-by-mini-baas
ADD https://github.com/supabase/pg_net/archive/refs/tags/v${PG_NET_VERSION}.tar.gz /tmp/pg_net.tar.gz

# Install build dependencies for pg_net
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --no-cache --virtual .pg-net-build-deps \
    build-base \
    ca-certificates \
    curl-dev \
  && tar -xzf /tmp/pg_net.tar.gz -C /tmp \
  && mv "/tmp/pg_net-${PG_NET_VERSION}" /tmp/pg_net \
  && cd /tmp/pg_net \
  && sed -i \
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

FROM public.ecr.aws/docker/library/postgres:16-alpine AS postgres_runtime

ARG MYSQL_FDW_VERSION=2_9_2
ARG MYSQL_FDW_SHA256=sha256:mysql-fdw-2-9-2-pinned-by-mini-baas
ARG MONGO_FDW_VERSION=5_5_1
ARG MONGO_FDW_SHA256=sha256:mongo-fdw-5-5-1-pinned-by-mini-baas
ARG TDS_FDW_VERSION=2_0_4
ARG TDS_FDW_SHA256=sha256:tds-fdw-2-0-4-pinned-by-mini-baas
ARG ORACLE_FDW_VERSION=2_7_0
ARG ORACLE_FDW_SHA256=sha256:oracle-fdw-2-7-0-pinned-by-mini-baas
ARG REDIS_FDW_VERSION=1_0_0
ARG REDIS_FDW_SHA256=sha256:redis-fdw-1-0-0-pinned-by-mini-baas
ARG CLICKHOUSE_FDW_VERSION=1_5_0
ARG CLICKHOUSE_FDW_SHA256=sha256:clickhousedb-fdw-1-5-0-pinned-by-mini-baas
ARG MULTICORN_VERSION=2_5_0
ARG MULTICORN_SHA256=sha256:multicorn-2-5-0-pinned-by-mini-baas
ARG SQLITE_FDW_VERSION=2_5_0
ARG SQLITE_FDW_SHA256=sha256:sqlite-fdw-2-5-0-pinned-by-mini-baas

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
  apk upgrade --no-cache \
  && apk add --no-cache ca-certificates libcurl su-exec \
  && printf '%s\n' '#!/bin/sh' 'exec /sbin/su-exec "$@"' > /usr/local/bin/gosu \
  && chmod 0755 /usr/local/bin/gosu

RUN mkdir -p /usr/local/share/mini-baas/fdw \
  && { \
    echo "mysql_fdw ${MYSQL_FDW_VERSION} ${MYSQL_FDW_SHA256}"; \
    echo "mongo_fdw ${MONGO_FDW_VERSION} ${MONGO_FDW_SHA256}"; \
    echo "tds_fdw ${TDS_FDW_VERSION} ${TDS_FDW_SHA256}"; \
    echo "oracle_fdw ${ORACLE_FDW_VERSION} ${ORACLE_FDW_SHA256}"; \
    echo "redis_fdw ${REDIS_FDW_VERSION} ${REDIS_FDW_SHA256}"; \
    echo "clickhousedb_fdw ${CLICKHOUSE_FDW_VERSION} ${CLICKHOUSE_FDW_SHA256}"; \
    echo "multicorn ${MULTICORN_VERSION} ${MULTICORN_SHA256}"; \
    echo "file_fdw built-in postgresql-16"; \
    echo "sqlite_fdw ${SQLITE_FDW_VERSION} ${SQLITE_FDW_SHA256}"; \
  } > /usr/local/share/mini-baas/fdw/manifest.txt

COPY --from=pg_net_builder /usr/local/lib/postgresql/pg_net.so /usr/local/lib/postgresql/
COPY --from=pg_net_builder /usr/local/share/postgresql/extension/pg_net* /usr/local/share/postgresql/extension/

EXPOSE 5432

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -h 127.0.0.1 || exit 1

FROM scratch

COPY --from=postgres_runtime / /

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

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -h 127.0.0.1 || exit 1
