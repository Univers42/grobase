# syntax=docker/dockerfile:1.7
# File: docker/services/postgres-graphql/Dockerfile
#
# A5 — GraphQL EDITION Postgres. Debian/glibc PostgreSQL 16 with pg_net AND
# pg_graphql, so PostgREST's /graphql endpoint is genuinely live.
#
# WHY A SEPARATE IMAGE: pg_graphql is a pgrx (Rust) extension. Upstream ships
# ONLY glibc artifacts (10 .deb files, pg14-18 × {amd64,arm64} linux-gnu) — there
# is NO musl/alpine build, and building it against the lean `postgres:16-alpine`
# default fails (pgrx #340: empty SQL-entity generation on musl). So the GraphQL
# edition runs on a Debian-glibc base and copies the OFFICIAL pg16 .deb. The lean
# alpine image stays the default (035_pg_graphql.sql no-ops there); opt into this
# variant via docker-compose.graphql.yml.
#
# SCOPE: this variant carries pg_net (gotrue/webhooks) + pg_graphql. It does NOT
# carry the cross-engine FDWs the alpine image builds — use the default edition
# for FDW features. (Porting the FDW source builds to Debian is a later effort.)

# ── builder: compile pg_net from source on Debian ───────────────────────────
FROM postgres:16-bookworm AS pg_net_builder
ARG PG_NET_VERSION=0.14.0
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential postgresql-server-dev-16 libcurl4-openssl-dev ca-certificates curl \
  && curl -fsSL -o /tmp/pg_net.tar.gz \
       "https://github.com/supabase/pg_net/archive/refs/tags/v${PG_NET_VERSION}.tar.gz" \
  && mkdir -p /tmp/pg_net \
  && tar -xzf /tmp/pg_net.tar.gz -C /tmp/pg_net --strip-components=1 \
  && cd /tmp/pg_net \
  # Disable libcurl's compile-time typecheck macros (same fix the alpine image
  # applies) so the build is compiler-agnostic; skip LLVM bitcode (no clang).
  && sed -i '1i#define CURL_DISABLE_TYPECHECK 1' src/core.c src/event.h src/errors.c src/util.c src/worker.c \
  && make with_llvm=no \
  && make install with_llvm=no \
  && rm -rf /tmp/pg_net /tmp/pg_net.tar.gz

# ── runtime: postgres:16-bookworm + pg_net + pg_graphql ─────────────────────
FROM postgres:16-bookworm AS runtime
ARG PG_GRAPHQL_VERSION=1.6.1
# pinned: pg_graphql-v1.6.1-pg16-amd64-linux-gnu.deb (verified 2026-06-13)
ARG PG_GRAPHQL_SHA256=0b25824a1d2955a34408726d4a3d05b0ccc11bde7baf3bf85f03c1a66423fdff

# pg_net artifacts from the builder (built against this exact server).
COPY --from=pg_net_builder /usr/lib/postgresql/16/lib/pg_net.so /usr/lib/postgresql/16/lib/
COPY --from=pg_net_builder /usr/share/postgresql/16/extension/pg_net* /usr/share/postgresql/16/extension/

# pg_graphql: the OFFICIAL prebuilt pg16 .deb, SHA-256 pinned (supply-chain
# discipline, like the alpine image's FDW manifest).
ADD https://github.com/supabase/pg_graphql/releases/download/v${PG_GRAPHQL_VERSION}/pg_graphql-v${PG_GRAPHQL_VERSION}-pg16-amd64-linux-gnu.deb /tmp/pg_graphql.deb
RUN echo "${PG_GRAPHQL_SHA256}  /tmp/pg_graphql.deb" | sha256sum -c - \
  && dpkg -i /tmp/pg_graphql.deb \
  && rm /tmp/pg_graphql.deb

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -h 127.0.0.1 || exit 1
