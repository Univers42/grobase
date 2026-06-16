# syntax=docker/dockerfile:1
# File: docker/services/minio/Dockerfile

FROM minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1
EXPOSE 9000 9001
USER 1001:1001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:9000/minio/health/live >/dev/null || exit 1
