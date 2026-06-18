# syntax=docker/dockerfile:1
# File: docker/services/mysql/Dockerfile
#
# Self-built "mysql" service from Alpine's own package — we do NOT pull the
# ready-made mysql:8.4 image (812 MB). Alpine is the only base we pull (allowed
# by the 42-Inception rule). Alpine has no Oracle-MySQL package; the
# Alpine-native MySQL-wire-compatible server is MariaDB 11.4 (mariadbd ships the
# mysqld/mysqld_safe symlinks and the mysqladmin client the compose healthcheck
# uses: `mysqladmin ping -h 127.0.0.1 -u root -p…`).
#
# See docker-entrypoint.sh for the MySQL-8 wire/plugin caveat. For this stack's
# usage (analytical federation + tenant CRUD via the query-router) the substitute
# is behavior-preserving: data path /var/lib/mysql, port 3306, MYSQL_* env
# contract, and a working `mysqladmin ping` healthcheck are all kept.
FROM alpine:3.21

RUN apk add --no-cache mariadb mariadb-client \
 && install -d -m 0755 -o mysql -g mysql /var/lib/mysql /run/mysqld

# Alpine's mariadb-server.cnf ships `skip-networking` ON, so mariadbd would bind
# only the unix socket — unreachable over TCP by the data plane, the conformance
# gate, and the compose `mysqladmin ping -h 127.0.0.1` healthcheck. Enable TCP on
# all interfaces (the container is already network-isolated by compose).
RUN sed -i -e 's/^skip-networking/#skip-networking/' \
           -e 's/^#\?bind-address=.*/bind-address=0.0.0.0/' \
           /etc/my.cnf.d/mariadb-server.cnf

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

EXPOSE 3306
USER mysql

# Mirrors the compose healthcheck (mysqladmin ping) for build-time smoke too.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD mysqladmin ping -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASSWORD:-}" || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mysqld"]
