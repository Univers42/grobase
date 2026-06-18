# syntax=docker/dockerfile:1
# File: docker/services/redis/Dockerfile
#
# Self-built Redis: installed from Alpine's own package — we do NOT pull the
# ready-made redis image. Alpine is the only base we pull (allowed by the rule).
# The redis-server flags + the redis-cli healthcheck come from docker-compose.yml;
# /data is pre-owned by the redis user so the named volume inherits that ownership
# on first creation (no entrypoint chown dance needed).
FROM alpine:3.21

RUN apk add --no-cache redis \
 && install -d -o redis -g redis /data

EXPOSE 6379
USER redis
WORKDIR /data

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD redis-cli ping | grep -q PONG || exit 1

# No ENTRYPOINT: docker-compose's `command: redis-server --appendonly yes …`
# replaces this CMD wholesale, so there is no doubled `redis-server`.
CMD ["redis-server"]
