# syntax=docker/dockerfile:1
FROM rust:1.83-slim AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/hypertube-stream /usr/local/bin/hypertube-stream
USER nobody
EXPOSE 3083
ENTRYPOINT ["/usr/local/bin/hypertube-stream"]
