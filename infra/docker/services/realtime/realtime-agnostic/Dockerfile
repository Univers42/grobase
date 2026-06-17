# syntax=docker/dockerfile:1.7
# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – Dependency layer (cached unless Cargo.toml / Cargo.lock change).
# Two complementary caches keep rebuilds fast:
#  - layer cache: this stub-manifest stage pre-compiles all dependencies;
#  - BuildKit cache mounts: the crates registry and target dir persist ACROSS
#    builds, so manifest changes don't re-download the registry and source
#    changes only recompile the crates that actually changed.
# NOTE: every workspace member's Cargo.toml must be COPY'd below — add new
# crates here or the stub build cannot resolve the workspace graph.
# ─────────────────────────────────────────────────────────────────────────────
FROM public.ecr.aws/docker/library/rust:1.89-slim-bookworm AS deps
WORKDIR /build

RUN --mount=type=cache,id=apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y pkg-config libssl-dev

# Copy manifests only — this layer is cached as long as deps don't change.
COPY Cargo.toml Cargo.lock ./
COPY crates/realtime-core/Cargo.toml          crates/realtime-core/Cargo.toml
COPY crates/realtime-engine/Cargo.toml        crates/realtime-engine/Cargo.toml
COPY crates/realtime-bus-inprocess/Cargo.toml crates/realtime-bus-inprocess/Cargo.toml
COPY crates/realtime-bus-irc/Cargo.toml       crates/realtime-bus-irc/Cargo.toml
COPY crates/realtime-auth/Cargo.toml          crates/realtime-auth/Cargo.toml
COPY crates/realtime-gateway/Cargo.toml       crates/realtime-gateway/Cargo.toml
COPY crates/realtime-db-postgres/Cargo.toml   crates/realtime-db-postgres/Cargo.toml
COPY crates/realtime-db-mongodb/Cargo.toml    crates/realtime-db-mongodb/Cargo.toml
COPY crates/realtime-server/Cargo.toml        crates/realtime-server/Cargo.toml
COPY crates/realtime-client/Cargo.toml        crates/realtime-client/Cargo.toml
COPY tests/integration/Cargo.toml             tests/integration/Cargo.toml

# Stub every crate so Cargo can resolve the graph, then pre-compile all
# dependencies (the slow step — cached until the manifests change).
RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=realtime-target,target=/build/target,sharing=locked \
    for dir in \
        crates/realtime-core \
        crates/realtime-engine \
        crates/realtime-bus-inprocess \
        crates/realtime-bus-irc \
        crates/realtime-auth \
        crates/realtime-gateway \
        crates/realtime-db-postgres \
        crates/realtime-db-mongodb \
        crates/realtime-client \
        tests/integration \
    ; do \
        mkdir -p "$dir/src" && echo "pub fn _placeholder() {}" > "$dir/src/lib.rs"; \
    done && \
    mkdir -p crates/realtime-server/src && \
    echo "fn main() {}" > crates/realtime-server/src/main.rs && \
    cargo build --release --bin realtime-server 2>&1 | tail -5

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – Application build (only re-runs when source code changes)
# ─────────────────────────────────────────────────────────────────────────────
FROM deps AS builder

# Copy real source (invalidates layer only when source actually changes).
COPY crates/ crates/
COPY tests/  tests/

# Touch sources so Cargo rebuilds the real crates over the stub fingerprints;
# the binary is copied OUT of the cache mount so it lands in the layer.
RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=realtime-target,target=/build/target,sharing=locked \
    find crates tests -name '*.rs' -exec touch {} + && \
    cargo build --release --bin realtime-server && \
    cp /build/target/release/realtime-server /realtime-server

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 – Minimal runtime image  (~15 MB stripped binary + libc)
# ─────────────────────────────────────────────────────────────────────────────
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

WORKDIR /app

COPY --from=builder --chown=nonroot:nonroot /realtime-server /app/realtime-server

# Default config file — override by mounting your own at this path.
COPY --chown=nonroot:nonroot realtime.toml /etc/realtime/realtime.toml

# Default static files (can be overridden via volume mount at runtime).
COPY --chown=nonroot:nonroot sandbox/static/ /app/static/

# Drop to non-root.
USER nonroot:nonroot

EXPOSE 4000

# Config file + env-var overrides.  Mount a custom TOML at the same path
# or set individual REALTIME_* env vars to override specific values.
ENV RUST_LOG="info" \
    REALTIME_CONFIG="/etc/realtime/realtime.toml" \
    REALTIME_HOST="0.0.0.0" \
    REALTIME_PORT="4000" \
    REALTIME_STATIC_DIR="/app/static"

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/app/realtime-server", "--healthcheck"]

CMD ["/app/realtime-server"]
