# syntax=docker/dockerfile:1
# File: docker/services/pg-meta/Dockerfile

FROM supabase/postgres-meta:v0.91.0
EXPOSE 8080
USER 1001:1001

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:8080/health >/dev/null 2>&1 || exit 1
