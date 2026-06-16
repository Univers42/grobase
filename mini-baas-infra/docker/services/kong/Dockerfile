# syntax=docker/dockerfile:1
# File: docker/services/kong/Dockerfile

FROM public.ecr.aws/docker/library/kong:3.8
COPY --link conf/kong.yml /etc/kong/kong.yml
ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yml \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_ADMIN_ACCESS_LOG=/dev/stdout \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_ADMIN_ERROR_LOG=/dev/stderr \
    KONG_ADMIN_LISTEN=0.0.0.0:8001
EXPOSE 8000 8001

HEALTHCHECK --interval=15s --timeout=3s --start-period=15s --retries=3 \
  CMD kong health || exit 1

# Kong's official image defines the `kong` user (UID 1000). Make it explicit
# so semgrep dockerfile.security.missing-user does not flag the image as
# running root, and so any subsequent layer cannot accidentally regress to
# root execution.
USER kong

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["kong", "docker-start"]
