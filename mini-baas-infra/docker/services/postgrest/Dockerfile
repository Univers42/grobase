# syntax=docker/dockerfile:1
# File: docker/services/postgrest/Dockerfile

FROM postgrest/postgrest:v12.2.3
EXPOSE 3000
USER 1001:1001

# PostgREST image is distroless-style: TCP probe via Haskell binary's own health.
# PostgREST responds 200 on / when ready to serve.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/ >/dev/null 2>&1 || exit 1
