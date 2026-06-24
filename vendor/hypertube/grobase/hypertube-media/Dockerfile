# syntax=docker/dockerfile:1
# hypertube-media — BitTorrent download + on-the-fly transcode/stream service.
# The final image is debian-slim (NOT distroless) because non-native containers
# are transcoded with the ffmpeg binary at runtime.
FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hypertube-media ./cmd/hypertube-media

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /hypertube-media /usr/local/bin/hypertube-media
USER nobody
EXPOSE 3080
ENTRYPOINT ["/usr/local/bin/hypertube-media"]
