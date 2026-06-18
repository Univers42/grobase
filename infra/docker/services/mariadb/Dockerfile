# syntax=docker/dockerfile:1
# File: docker/services/mariadb/Dockerfile
#
# Self-built MariaDB from Alpine's own package — we do NOT pull the ready-made
# mariadb image. Alpine is the only base we pull (allowed by the 42-Inception
# rule). Alpine 3.21 ships MariaDB 11.4.x (`mariadb` + `mariadb-client`), which
# provides the mariadbd server and the mysqld/mysqld_safe-compatible symlinks.
#
# Two upstream-only helpers are reimplemented as small scripts so the
# docker-compose.yml contract is preserved byte-for-byte:
#   * docker-entrypoint.sh — first-boot init from MARIADB_*/MYSQL_* env vars
#   * healthcheck.sh       — the `healthcheck.sh --connect --innodb_initialized`
#                            command the compose healthcheck invokes.
# Data lives in /var/lib/mysql (the mariadb-data named volume), pre-owned by the
# mysql user so the volume inherits that ownership on first creation.
FROM alpine:3.21

RUN apk add --no-cache mariadb mariadb-client \
 && install -d -m 0755 -o mysql -g mysql /var/lib/mysql /run/mysqld

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=0755 healthcheck.sh       /usr/local/bin/healthcheck.sh

EXPOSE 3306
USER mysql

# Mirrors the compose healthcheck so `docker build`-only smoke also has a probe.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD healthcheck.sh --connect --innodb_initialized || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mariadbd"]
