# syntax=docker/dockerfile:1
# File: docker/services/redis/Dockerfile

FROM public.ecr.aws/docker/library/redis:7-alpine
EXPOSE 6379
USER redis

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD redis-cli ping | grep -q PONG || exit 1
