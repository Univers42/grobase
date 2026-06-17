# syntax=docker/dockerfile:1
# File: docker/services/mongo-init/Dockerfile
#
# 42-Inception: self-built replica-set initialiser on the slimmest base WE
# control. The mongo-init container runs ONCE and only executes
#   bash -c 'mongosh --host mongo ... rs.initiate(...)'
# over the network — it needs NO mongod server, only `bash` + `mongosh`.
# That is the big win: the 874 MB `mongo:7` image collapses to just the shell.
#
# mongosh is musl-incompatible (needs glibc) -> debian:bookworm-slim, NOT alpine.
# We install the OFFICIAL `mongodb-mongosh` apt package (a package, not a
# ready-made fat image -> compliant). No server, no tools, apt lists stripped.
#
# Compose contract: entrypoint is overridden to `bash -c '...mongosh...'`, so
# the image only needs bash + mongosh on PATH. The init only connects over the
# network (no local files), so a non-root user is fine.
FROM debian:bookworm-slim

ARG MONGO_MAJOR=7.0

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg bash; \
    curl -fsSL "https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc" \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg; \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/${MONGO_MAJOR} main" \
        > /etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends mongodb-mongosh; \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*; \
    # Docs/man/info/locale are never needed at runtime (mongosh + bash only).
    rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/groff \
           /usr/share/lintian /usr/share/linda /usr/share/locale/*; \
    # mongo-init only opens a plain network connection to run rs.initiate — it
    # never uses client-side field-level encryption, so drop the 114 MB FLE
    # crypto shared lib. mongosh runs fine without it for this use.
    rm -f /usr/lib/mongosh_crypt_v1.so

# Non-root: the init only opens a network connection to the mongo service.
RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin mongoinit
USER mongoinit

# No custom ENTRYPOINT: compose fully overrides `entrypoint` with its own
# `["bash","-c", "<rs.initiate script>"]`, and leaving the image entrypoint
# empty means `docker run img mongosh ...` / `docker run img bash -c ...`
# resolve the binaries directly (correct for smoke tests too).
CMD ["mongosh", "--version"]
