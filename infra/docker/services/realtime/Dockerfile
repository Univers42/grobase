# syntax=docker/dockerfile:1
# File: docker/services/realtime/Dockerfile
#
# Thin wrapper over the realtime-agnostic image. NOTE: compose builds the
# `realtime` service straight from ./realtime-agnostic (this file is NOT in
# that path) — keep this wrapper aligned with the locally-built tag, never a
# stale registry digest. `docker compose build realtime` produces the tag.
FROM dlesieur/realtime-agnostic:latest
EXPOSE 4000
USER nonroot:nonroot

# The base image is distroless (no shell, no curl/wget): probe through the
# binary itself, which checks /v1/health on the configured port.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/app/realtime-server", "--healthcheck"]
