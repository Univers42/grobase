# Docker official images; mirror.gcr.io serves Docker Hub's digests without
# public.ecr.aws's anonymous data cap (public.ecr.aws/docker/library works too).
ARG BASE_REGISTRY=mirror.gcr.io/library
FROM ${BASE_REGISTRY}/rust:1.89-slim-bookworm AS builder
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY tests/ tests/
# Build the release binary
RUN cargo build --release --bin realtime-server

FROM ${BASE_REGISTRY}/debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 1001 app \
 && useradd  -u 1001 -g app -d /app -s /sbin/nologin app
WORKDIR /app
COPY --from=builder --chown=app:app /build/target/release/realtime-server /app/realtime-server
COPY --chown=app:app sandbox/static/ /app/static/
EXPOSE 4000

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:4000/v1/health >/dev/null 2>&1 || exit 1

# Drop root before serving traffic (semgrep dockerfile.security.missing-user).
USER app
CMD ["/app/realtime-server"]
