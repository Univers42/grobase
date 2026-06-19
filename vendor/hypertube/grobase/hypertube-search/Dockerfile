# syntax=docker/dockerfile:1
# Hypertube search — a stdlib-only Go service that aggregates royalty-free
# torrent sources (archive.org + publicdomaintorrents.info) and enriches them
# with TMDb. Go's net/http does dual-stack Happy-Eyeballs, so outbound works on
# the IPv4-only bridge net.
FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hypertube-search ./cmd/hypertube-search

# distroless static carries ca-certificates (needed for the TMDb/archive.org TLS handshake).
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /hypertube-search /hypertube-search
EXPOSE 3081
USER nonroot:nonroot
ENTRYPOINT ["/hypertube-search"]
