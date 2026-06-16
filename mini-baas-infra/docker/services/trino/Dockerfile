# syntax=docker/dockerfile:1
# File: docker/services/trino/Dockerfile

FROM trinodb/trino:467
COPY --link conf/config.properties /etc/trino/config.properties
EXPOSE 8080
USER trino

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://localhost:8080/v1/info >/dev/null || exit 1
