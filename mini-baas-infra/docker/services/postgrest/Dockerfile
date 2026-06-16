# syntax=docker/dockerfile:1
# File: docker/services/postgrest/Dockerfile
#
# Self-built PostgREST. We do NOT pull the ready-made postgrest image — we fetch the
# upstream STATIC-musl release BINARY (a binary, not an image: compliant) and drop it
# onto `scratch` (matching the nano philosophy). A static busybox provides the wget
# the healthcheck needs. PostgREST reads PGRST_* from the env compose passes; the
# internal Postgres is non-TLS + JWT is HS256, so no CA bundle is required. ~18 MB.
FROM alpine:3.21 AS fetch
ARG PGRST_VERSION=v12.2.3
ARG PGRST_ARCH=linux-static-x64
RUN apk add --no-cache wget xz tar busybox-static \
 && wget -qO /tmp/pgrst.tar.xz \
      "https://github.com/PostgREST/postgrest/releases/download/${PGRST_VERSION}/postgrest-${PGRST_VERSION}-${PGRST_ARCH}.tar.xz" \
 && tar -xJf /tmp/pgrst.tar.xz -C /usr/local/bin postgrest \
 && chmod +x /usr/local/bin/postgrest \
 && /usr/local/bin/postgrest --help >/dev/null

FROM scratch
COPY --from=fetch /usr/local/bin/postgrest /bin/postgrest
COPY --from=fetch /bin/busybox.static /bin/busybox
EXPOSE 3000
USER 1001:1001
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["/bin/busybox", "wget", "-qO-", "http://localhost:3000/"]
ENTRYPOINT ["/bin/postgrest"]
