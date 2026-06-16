# syntax=docker/dockerfile:1
# File: docker/services/kong/Dockerfile
#
# 42-Inception: self-built Kong. We do NOT `FROM kong:3.8` (a ready-made fat
# vendor app image). Instead we install Kong's official Debian .deb package
# (OpenResty + nginx + LuaJIT bundled) onto a minimal base we control. A package
# is a compliant input; a ready-made application image is not.
#
# Recipe mirrors the upstream MIT Kong/docker-kong `Dockerfile.deb` so the
# resulting image is a drop-in for `kong:3.8` (same /docker-entrypoint.sh, same
# `kong` user UID 1000, same prefix /usr/local/kong, same `kong docker-start`).
# The entrypoint is vendored verbatim from Kong/docker-kong (MIT) at
# tools/docker-entrypoint.sh.

FROM debian:bookworm-slim

# Kong 3.8.0 deprecated Alpine; bookworm-slim is the supported minimal base.
ARG KONG_VERSION=3.8.0
# sha256 of kong_3.8.0_amd64.deb from packages.konghq.com (gateway-38, bookworm).
ARG KONG_SHA256=3eca0f8f72d923f8a20c68ad5c2abce3360e1a8d796571b2562ffa66be06702c
ARG KONG_PREFIX=/usr/local/kong
ENV KONG_PREFIX=${KONG_PREFIX}

# Download + install the official Kong .deb, resolve its apt deps, then strip
# the build-only bits (curl, apt lists, the .deb) in the same layer so nothing
# leaks into the final image. The .deb's postinst creates the `kong` user/group.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    DOWNLOAD_URL="https://packages.konghq.com/public/gateway-38/deb/debian/pool/bookworm/main/k/ko/kong_${KONG_VERSION}/kong_${KONG_VERSION}_amd64.deb"; \
    curl -fL "${DOWNLOAD_URL}" -o /tmp/kong.deb; \
    echo "${KONG_SHA256}  /tmp/kong.deb" | sha256sum -c -; \
    apt-get install -y --no-install-recommends /tmp/kong.deb; \
    rm -f /tmp/kong.deb; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*; \
    # Convenience symlinks the official image ships (resty/luajit/lua/nginx).
    ln -sf /usr/local/openresty/bin/resty /usr/local/bin/resty; \
    ln -sf /usr/local/openresty/luajit/bin/luajit /usr/local/bin/luajit; \
    ln -sf /usr/local/openresty/luajit/bin/luajit /usr/local/bin/lua; \
    ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/local/bin/nginx; \
    # Kong owns its binary + prefix (group 0 for OpenShift-style arbitrary UID).
    mkdir -p "${KONG_PREFIX}" /etc/kong; \
    chown kong:0 /usr/local/bin/kong; \
    chown -R kong:0 "${KONG_PREFIX}" /etc/kong; \
    # Fail the build if the deb did not give us `kong` at UID 1000 (contract).
    [ "$(id -u kong)" = "1000" ] || { echo "FATAL: kong uid != 1000 (got $(id -u kong))"; exit 1; }; \
    kong version

# Vendored upstream entrypoint (MIT). Handles `kong docker-start`: prepares the
# prefix then execs nginx in the foreground.
COPY tools/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Baked-in declarative config for standalone runs. (Compose overlays its own
# templated /tmp/kong.yml via KONG_DECLARATIVE_CONFIG; this is the fallback.)
COPY conf/kong.yml /etc/kong/kong.yml
RUN chown kong:0 /etc/kong/kong.yml

ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yml \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_ADMIN_ACCESS_LOG=/dev/stdout \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_ADMIN_ERROR_LOG=/dev/stderr \
    KONG_ADMIN_LISTEN=0.0.0.0:8001

EXPOSE 8000 8001
STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=15s --timeout=3s --start-period=15s --retries=3 \
  CMD kong health || exit 1

# Run as the unprivileged `kong` user (UID 1000) created by the .deb so semgrep
# dockerfile.security.missing-user does not flag the image, and no later layer
# can regress to root.
USER kong

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["kong", "docker-start"]
