# syntax=docker/dockerfile:1
# File: docker/services/gotrue/Dockerfile

FROM supabase/gotrue:v2.188.1
EXPOSE 9999
USER 1001:1001

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:9999/health >/dev/null 2>&1 || exit 1
