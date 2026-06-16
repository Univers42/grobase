# syntax=docker/dockerfile:1.7
# File: docker/services/supavisor/Dockerfile
#
# 42-Inception: build supabase/supavisor FROM SOURCE on our own slim bases —
# we do NOT pull the ready-made supabase/supavisor application image.
# Only a lightweight Elixir/Alpine build image and alpine:3.21 runtime are
# pulled.  An Erlang/OTP `mix release` bundles its own ERTS, so it runs on a
# bare Alpine runtime carrying just the C shared libs the BEAM needs.
#
# Versions pinned to supavisor v2.7.4's .tool-versions:
#   elixir 1.18.2 · erlang 27.2 (hexpm ships the 27.2.1 OTP point release) ·
#   rust 1.84.1 (the native/ NIFs need a Rust toolchain at build time).
#
# Pattern (matches the task's Elixir recipe):
#   build  : hexpm/elixir-alpine -> mix deps.get/compile + mix release supavisor
#   runtime: alpine:3.21 + ncurses-libs libstdc++ openssl libgcc -> copy release
#
# Upstream reference: MIX_ENV=prod, release `supavisor` at
# _build/prod/rel/supavisor, started via `bin/server`, wrapped by limits.sh
# (ulimit -n $RLIMIT_NOFILE then exec).  We inline that wrapper.

ARG ELIXIR_IMAGE=hexpm/elixir:1.18.2-erlang-27.2.1-alpine-3.21.2
ARG ALPINE_VERSION=3.21
ARG SUPAVISOR_VERSION=v2.7.4

# ─── Stage 1: build the Elixir release ───────────────────────────
FROM ${ELIXIR_IMAGE} AS build
ARG SUPAVISOR_VERSION
ENV MIX_ENV=prod

# build-base/cmake/openssl-dev: compile NIFs and crypto.  git: clone the tag.
# rust+cargo: supavisor's native/ Rust NIFs (pgparser uses rustler + bindgen).
# clang/clang-dev/llvm-dev: bindgen needs libclang.so to generate the pg_query
# C bindings (upstream installs libclang-dev for the same reason).
# npm: asset step in some mix tasks.  wget: bootstrap hex/rebar over OpenSSL TLS.
RUN apk add --no-cache git build-base cmake openssl-dev ncurses-dev \
      rust cargo clang clang-dev llvm-dev npm bash wget
# bindgen finds libclang via LIBCLANG_PATH; point it at Alpine's clang libdir.
ENV LIBCLANG_PATH=/usr/lib

WORKDIR /app
RUN git clone --depth 1 --branch "${SUPAVISOR_VERSION}" \
      https://github.com/supabase/supavisor.git . \
  && rm -rf .git

# Bootstrap Hex + rebar3 WITHOUT `mix local.hex` / `mix local.rebar`.
# Reason: OTP 27's strict :ssl rejects the builds.hex.pm certificate chain with
# `key_usage_mismatch` (an OTP-27 RFC-5280 keyUsage regression), so Mix's own
# pure-Erlang downloader cannot fetch hex/rebar.  wget (OpenSSL) is lenient, so
# we pull the OTP-27-compatible hex archive (the 1.16.0 build line) + rebar3
# binary leniently and install hex offline.  Pinned for reproducibility.
ARG HEX_VERSION=2.4.2
ARG HEX_ELIXIR_BUILD=1.16.0
ARG REBAR3_VERSION=3.24.0
RUN set -eux; \
  wget -qO /tmp/hex.ez "https://builds.hex.pm/installs/${HEX_ELIXIR_BUILD}/hex-${HEX_VERSION}.ez"; \
  mix archive.install /tmp/hex.ez --force; \
  wget -qO /usr/local/bin/rebar3 "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3"; \
  chmod +x /usr/local/bin/rebar3; \
  mix local.rebar rebar3 /usr/local/bin/rebar3 --force

# hex's own HTTP layer also talks to repo.hex.pm over the same OTP-strict TLS;
# HEX_UNSAFE_HTTPS=1 switches it to verify_none so deps resolve.  (Build-only;
# never reaches the runtime image.)  NOTE: we deliberately do NOT cache-mount
# /root/.mix or /root/.hex here — a cache mount would mask the hex/rebar
# archives just installed above, making Mix try to re-bootstrap hex over the
# broken TLS.  Only the cargo registry is cache-mounted (a disjoint path).
ENV HEX_UNSAFE_HTTPS=1
RUN --mount=type=cache,target=/root/.cargo,sharing=locked \
  mix deps.get --only prod
RUN --mount=type=cache,target=/root/.cargo,sharing=locked \
  mix deps.compile
RUN --mount=type=cache,target=/root/.cargo,sharing=locked \
  mix compile
RUN mix release supavisor

# ─── Stage 2: minimal Alpine runtime ─────────────────────────────
FROM public.ecr.aws/docker/library/alpine:${ALPINE_VERSION} AS runtime
# The BEAM release ships its own ERTS; it only needs these C shared libs.
# bash: the limits wrapper uses it (upstream limits.sh is a bash script).
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl bash

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    RLIMIT_NOFILE=100000 \
    ECTO_IPV6=true \
    ERL_AFLAGS="-proto_dist inet6_tcp"

# Non-root, parity with the compose `USER 1001`.
RUN addgroup -S -g 1001 app && adduser -S -u 1001 -G app app
WORKDIR /app

# Copy the self-contained release tree (ERTS + compiled BEAM + NIFs).
COPY --from=build --chown=1001:1001 /app/_build/prod/rel/supavisor ./

# Inline limits.sh: raise RLIMIT_NOFILE then exec the release foreground server.
# Equivalent to upstream's ENTRYPOINT tini -> limits.sh, CMD bin/server.
RUN printf '#!/bin/sh\nset -eu\nif [ -n "${RLIMIT_NOFILE:-}" ]; then ulimit -n "$RLIMIT_NOFILE" || true; fi\nexec /app/bin/server\n' \
      > /app/limits.sh \
  && chmod 0555 /app/limits.sh

USER 1001:1001
# Supavisor pools PG on 6543 (client) and serves its API/metrics on 4000.
EXPOSE 6543 4000

# The release exposes a `pid` command that returns 0 once the BEAM + supavisor
# app are up — matches the compose healthcheck shape for this service.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD /app/bin/supavisor pid >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/app/limits.sh"]
