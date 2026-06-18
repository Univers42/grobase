# syntax=docker/dockerfile:1.7
# Two complementary caches keep rebuilds fast:
#  - layer cache: the stub-manifest stage pre-compiles all dependencies, so the
#    expensive dep build is reused as long as no Cargo.toml/lock changes;
#  - BuildKit cache mounts: the crates registry and the target dir persist
#    ACROSS builds, so a manifest change no longer re-downloads the registry,
#    and a source change only recompiles the crates that actually changed.
FROM public.ecr.aws/docker/library/rust:1.96-slim-bookworm AS deps
WORKDIR /build

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
    cargo build --release --bin data-plane-router

FROM deps AS builder
COPY crates/ crates/
RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=dpr-target,target=/build/target,sharing=locked \
    touch crates/data-plane-core/src/*.rs crates/data-plane-pool/src/*.rs crates/data-plane-server/src/*.rs && \
    cargo build --release --bin data-plane-router && \
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
