# syntax=docker/dockerfile:1
# File: docker/services/mongo/Dockerfile
#
# 42-Inception: self-built MongoDB 7.0 server on the slimmest base WE control.
# MongoDB is musl-incompatible (needs glibc) -> debian:bookworm-slim, NOT alpine.
# We install the OFFICIAL MongoDB apt packages (server-only meta-pkg + mongosh),
# which is compliant (a package is not a ready-made fat image). This drops the
# 874 MB `mongo:7` image to ~700 MB by dropping the bundled tools/cruft and
# stripping apt lists & caches.
#
# Runtime contract replicated from the official image:
#   * ENTRYPOINT = docker-entrypoint.sh -> exec mongod "$@" (compose appends
#     --replSet rs0 --bind_ip_all --keyFile /etc/mongo/rs-keyfile).
#   * Runs as uid/gid 999 (mongodb), matching the keyfile chown 999:999 and
#     the mounted data volume.
#   * First-boot root user from MONGO_INITDB_ROOT_USERNAME/PASSWORD when /data/db
#     is empty (compact equivalent of upstream docker-entrypoint.sh initdb).
#   * mongosh present for the replica-set healthcheck.
FROM debian:bookworm-slim

ARG MONGO_MAJOR=7.0

# gpg/curl/ca-certificates are needed only to add the apt repo; remove afterwards.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg; \
    curl -fsSL "https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc" \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg; \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/${MONGO_MAJOR} main" \
        > /etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mongodb-org-server \
        mongodb-mongosh; \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*; \
    # Docs/man/info/locale are never read at runtime (mongod + mongosh only).
    rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/groff \
           /usr/share/lintian /usr/share/linda /usr/share/locale/*; \
    # Drop bulky log/data dirs the package ships; we mount our own volumes.
    rm -rf /var/log/mongodb /var/lib/mongodb

# Match the official image: group+user 999, data dir owned by 999.
# The mongodb-org-server package already creates a `mongodb` user/group, but at
# a distro-assigned id; force it to 999 (the keyfile is chowned 999:999, the
# data volume is mounted, and compose has no `user:` override).
RUN set -eux; \
    if getent group mongodb >/dev/null; then groupmod --gid 999 mongodb; \
    else groupadd --gid 999 --system mongodb; fi; \
    if id mongodb >/dev/null 2>&1; then \
        usermod --uid 999 --gid 999 --home /data/db --shell /usr/sbin/nologin mongodb; \
    else \
        useradd --uid 999 --system --gid 999 --home-dir /data/db --shell /usr/sbin/nologin mongodb; \
    fi; \
    mkdir -p /data/db /data/configdb /etc/mongo; \
    chown -R 999:999 /data/db /data/configdb

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME /data/db /data/configdb
EXPOSE 27017
USER mongodb

ENTRYPOINT ["docker-entrypoint.sh"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD mongosh --quiet --eval "try { rs.status().myState === 1 ? quit(0) : quit(1) } catch(e) { db.runCommand({ ping: 1 }).ok ? quit(0) : quit(1) }" || exit 1

CMD ["mongod", "--bind_ip_all"]
