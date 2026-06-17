# syntax=docker/dockerfile:1.7
# File: docker/services/mssql/Dockerfile
#
# 42-Inception: build SQL Server FROM OUR OWN Dockerfile on a base we control —
# we do NOT pull the ready-made mcr.microsoft.com/mssql/server application image.
#
# MUSL-INCOMPATIBLE + Microsoft-only: SQL Server requires a glibc Ubuntu/RHEL
# userland (no Alpine/musl build exists), so per the slimming rule the slim
# choice is the SLIMMEST BASE MICROSOFT SUPPORTS: ubuntu:22.04.  We then install
# mssql-server straight from Microsoft's apt repo (packages.microsoft.com) — the
# documented public install path — instead of pulling MS's prebuilt image.
#
# SQL Server is inherently ~1.5 GB; the win here is PROVENANCE (our Dockerfile,
# our base, pinned repo) not bytes.  mssql-tools18 is included because the
# compose healthcheck runs /opt/mssql-tools18/bin/sqlcmd.
#
# Runtime contract preserved from the compose block:
#   env ACCEPT_EULA / MSSQL_SA_PASSWORD / MSSQL_PID  ·  data /var/opt/mssql
#   EXPOSE 1433  ·  process /opt/mssql/bin/sqlservr  ·  runs as the mssql user.

FROM ubuntu:22.04

ARG MSSQL_MAJOR=2022
ARG DEBIAN_FRONTEND=noninteractive

# 1) bootstrap apt + Microsoft's signed repos (server + prod-for-tools), 2) install
# SQL Server, the ODBC18 tools (sqlcmd for the healthcheck) and their deps, then
# 3) strip apt caches.  --no-install-recommends keeps the layer minimal.
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg apt-transport-https locales; \
  # Microsoft package-signing key (de-armored to the keyring).
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg; \
  # SQL Server engine repo + general prod repo (mssql-tools18 lives in prod).
  curl -fsSL "https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-${MSSQL_MAJOR}.list" \
    -o /etc/apt/sources.list.d/mssql-server.list; \
  curl -fsSL "https://packages.microsoft.com/config/ubuntu/22.04/prod.list" \
    -o /etc/apt/sources.list.d/microsoft-prod.list; \
  # Pin both repos to the Microsoft keyring (avoids the deprecated apt-key path).
  # MS serves these as `deb [arch=amd64,...] URL ...`, so merge signed-by INTO
  # the existing options block rather than adding a second `[...]` group (apt
  # rejects two bracket groups as a malformed URI).
  sed -i 's#\[arch=#[signed-by=/usr/share/keyrings/microsoft-prod.gpg arch=#' \
    /etc/apt/sources.list.d/mssql-server.list /etc/apt/sources.list.d/microsoft-prod.list; \
  apt-get update; \
  # EULA must be pre-accepted for the unattended tools install.
  ACCEPT_EULA=Y apt-get install -y --no-install-recommends \
    mssql-server mssql-tools18 unixodbc-dev; \
  # locale (sqlservr wants a UTF-8 locale). The compiled en_US.UTF-8 lives in
  # /usr/lib/locale/locale-archive — KEEP that; LANG/LC_ALL below depend on it.
  locale-gen en_US.UTF-8; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*; \
  # Docs/man/info are never read at runtime (sqlservr + sqlcmd only).
  # /usr/share/locale holds GNU gettext .mo app translations (apt/dpkg/coreutils
  # messages) — NOT the en_US.UTF-8 runtime locale (that's the compiled archive
  # in /usr/lib/locale, left intact) — so pruning it is safe and keeps en_US.
  rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/groff \
         /usr/share/lintian /usr/share/linda /usr/share/locale/*

# sqlcmd / bcp on PATH for interactive + healthcheck use.
ENV PATH="/opt/mssql-tools18/bin:${PATH}" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# The mssql-server package creates the `mssql` user (uid 10001) and owns
# /var/opt/mssql.  Ensure the data dir exists + is owned for the volume mount.
RUN mkdir -p /var/opt/mssql && chown -R mssql:mssql /var/opt/mssql

# Default SQL Server TCP port.
EXPOSE 1433

# Run as the non-root mssql user (least privilege; matches MS guidance).
USER mssql
WORKDIR /var/opt/mssql

# Compose owns the authoritative healthcheck (sqlcmd SELECT 1); this is a
# build-image fallback that confirms the engine is answering on 1433.
HEALTHCHECK --interval=15s --timeout=5s --start-period=45s --retries=10 \
  CMD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" \
      -C -No -Q "SELECT 1" -b -o /dev/null || exit 1

# sqlservr reads ACCEPT_EULA / MSSQL_SA_PASSWORD / MSSQL_PID from the env that
# compose injects — same entrypoint the official image uses.
ENTRYPOINT ["/opt/mssql/bin/sqlservr"]
