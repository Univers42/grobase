# syntax=docker/dockerfile:1
# MovieVerse TMDB proxy — a tiny stdlib-only Go service. Go's net/http does
# dual-stack Happy-Eyeballs, so outbound to api.themoviedb.org works on the
# IPv4-only bridge net (the Deno functions runtime hangs on the AAAA address).
FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /tmdb-proxy ./cmd/tmdb-proxy

# distroless static carries ca-certificates (needed for the TMDB TLS handshake).
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /tmdb-proxy /tmdb-proxy
EXPOSE 3070
USER nonroot:nonroot
ENTRYPOINT ["/tmdb-proxy"]
