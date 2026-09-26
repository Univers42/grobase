# syntax=docker/dockerfile:1.7
# Two complementary caches keep rebuilds fast:
#  - layer cache: the stub-manifest stage pre-compiles all dependencies, so the
#    expensive dep build is reused as long as no Cargo.toml/lock changes;
#  - BuildKit cache mounts: the crates registry and the target dir persist
#    ACROSS builds, so a manifest change no longer re-downloads the registry,
#    and a source change only recompiles the crates that actually changed.
# The registry/git mounts are sharing=shared (cargo does its own file locking)
# so this build and the realtime workspace compile CONCURRENTLY instead of
# serializing on the mount lock; only the per-workspace target dir stays locked.
# Docker official images; mirror.gcr.io serves Docker Hub's digests without
# public.ecr.aws's anonymous data cap (public.ecr.aws/docker/library works too).
ARG BASE_REGISTRY=mirror.gcr.io/library
FROM ${BASE_REGISTRY}/rust:1.96-slim-bookworm@sha256:e18a79fc84dfcfc3ab5ba72290398a644c135c97eaa881447fddc354ee4701a3 AS deps
# crates.io downloads flake in CI ("Error in the HTTP2 framing layer"); HTTP/1.1 plus
# retries is the same mitigation ci.yml's rust unit-test job uses. Build stage only.
ENV CARGO_NET_RETRY=10 \
    CARGO_HTTP_MULTIPLEXING=false
WORKDIR /build
# Opt-in extra cargo features for THIS deployment (e.g. "--features dynamodb").
# Default empty → byte-parity with the shipped 7-engine build.
ARG DATA_PLANE_FEATURES=""

COPY Cargo.toml ./
COPY crates/data-plane-core/Cargo.toml crates/data-plane-core/Cargo.toml
COPY crates/data-plane-pool/Cargo.toml crates/data-plane-pool/Cargo.toml
COPY crates/data-plane-server/Cargo.toml crates/data-plane-server/Cargo.toml
# engine-conformance is a workspace member (test-only). Its manifest must be
# present for cargo to parse the workspace, but default-members keeps it out of
# the bin build, so a stub lib is enough — its deps are never compiled here.
COPY crates/engine-conformance/Cargo.toml crates/engine-conformance/Cargo.toml

RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=dpr-target,target=/build/target,sharing=locked \
    for dir in crates/data-plane-core crates/data-plane-pool crates/data-plane-server crates/engine-conformance; do \
      mkdir -p "$dir/src"; \
      echo "pub fn placeholder() {}" > "$dir/src/lib.rs"; \
    done && \
    echo "fn main() {}" > crates/data-plane-server/src/main.rs && \
    cargo build --release ${DATA_PLANE_FEATURES} --bin data-plane-router && \
    find /build/target -path '*/.fingerprint/*' -type f -exec touch -t 200001010000 {} +

FROM deps AS builder
ARG DATA_PLANE_FEATURES=""
COPY crates/ crates/
RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=dpr-target,target=/build/target,sharing=locked \
    cargo build --release ${DATA_PLANE_FEATURES} --bin data-plane-router && \
    cp /build/target/release/data-plane-router /data-plane-router

FROM gcr.io/distroless/cc-debian12:nonroot AS runtime
WORKDIR /app

COPY --from=builder --chown=nonroot:nonroot /data-plane-router /app/data-plane-router

USER nonroot:nonroot
EXPOSE 4011

ENV RUST_LOG="info" \
    DATA_PLANE_ROUTER_HOST="0.0.0.0" \
    DATA_PLANE_ROUTER_PORT="4011" \
    DATA_PLANE_ROUTER_PRODUCT_MODE="shadow"

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/app/data-plane-router", "--healthcheck"]

CMD ["/app/data-plane-router"]
