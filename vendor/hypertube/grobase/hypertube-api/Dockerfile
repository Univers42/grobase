# syntax=docker/dockerfile:1
# Hypertube RESTful OAuth2 API — a stdlib-only Go service. Go's net/http does
# dual-stack Happy-Eyeballs, so its calls to Kong + GoTrue work on the bridge net.
FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hypertube-api ./cmd/hypertube-api

# distroless static carries ca-certificates for any TLS hop the gateway forwards.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /hypertube-api /hypertube-api
EXPOSE 3082
USER nonroot:nonroot
ENTRYPOINT ["/hypertube-api"]
