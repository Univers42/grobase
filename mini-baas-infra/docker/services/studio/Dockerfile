# syntax=docker/dockerfile:1
# File: docker/services/studio/Dockerfile

FROM supabase/studio:2026.03.30-sha-12a43e5
EXPOSE 3000
USER 1001:1001

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000').then(() => process.exit(0)).catch(() => process.exit(1))" || exit 1
