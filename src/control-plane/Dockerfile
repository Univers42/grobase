# Go control-plane image. Multi-stage build, parameterized by `APP` to keep one
# Dockerfile per cmd binary (adapter-registry, webhook-dispatcher, …).
#
# Build example:
#   docker build --build-arg APP=webhook-dispatcher --build-arg PORT=3025 \
#     -t mini-baas-webhook-dispatcher ./go/control-plane

ARG APP=adapter-registry
ARG PORT=3021

# Go 1.25 build toolchain — pulls the patched stdlib (crypto/x509, crypto/tls,
# net/http, net/url, os) that closes the ~10 GO-2026-* advisories govulncheck
# flags at go1.23 (a stdlib-only fix; no code change). `make verify-deps` re-scans.
FROM golang:1.25-bookworm AS builder
ARG APP
WORKDIR /src

# Module + build caches persist across builds (and across the APP variants),
# so each binary build only compiles what changed instead of cold-compiling
# the whole dependency graph per app.
COPY go.mod go.sum* ./
ENV GOFLAGS=-mod=mod
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod,sharing=locked \
    go mod download all || true

COPY . .
# -mod=mod lets the build resolve anything go.sum is missing; `go mod tidy`
# at image-build time rewrote go.mod inside the image (non-reproducible) and
# re-resolved the graph on every build.
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=gobuild,target=/root/.cache/go-build,sharing=locked \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/app ./cmd/${APP}

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
ARG APP
ARG PORT
WORKDIR /app
COPY --from=builder /out/app /app/app

ENV APP=${APP}
EXPOSE ${PORT}
# Distroless has no shell — probe via the binary's own `--healthcheck` subcommand
# (every cmd/<app>/main.go handles os.Args[1] == "--healthcheck"), mirroring the
# data-plane image. M1 hardening gate: every service Dockerfile carries a HEALTHCHECK.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD ["/app/app", "--healthcheck"]
USER nonroot:nonroot
ENTRYPOINT ["/app/app"]
