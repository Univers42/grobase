# syntax=docker/dockerfile:1
# File: docker/services/mysql8/Dockerfile
#
# Self-built Oracle MySQL 8.4 LTS. The `mysql` service is MariaDB 11.4 (Alpine has no MySQL
# package, see ../mysql/docker-entrypoint.sh), so nothing proved the stack against real MySQL.
# We fetch Oracle's glibc "minimal" release TARBALL (a binary artifact, NOT the mysql:8.4
# image) from the archive path, which stays stable after a newer release ships, and keep
# only the server, mysqladmin, the mysql client and what they load.
#
# Base note: the build is glibc-linked, so debian:bookworm-slim, as for cockroach.
# The pin is the version + sha256 below; BuildKit verifies the checksum before extracting.

# ── fetch: verify + extract the release tarball ──────────────────────────────
FROM debian:bookworm-slim AS fetch
ARG MYSQL_TARBALL=mysql-8.4.9-linux-glibc2.28-x86_64-minimal
ADD --checksum=sha256:d0142fc30e04bae7f15a46567238adf8956acccd35c5bca6e448322644536e3d \
  https://cdn.mysql.com/archives/mysql-8.4/${MYSQL_TARBALL}.tar.xz /tmp/mysql.tar.xz
# bin/* find lib/private through RUNPATH $ORIGIN/../lib/private (OpenSSL 3, protobuf,
# abseil); share/ holds the error messages and charsets mysqld loads from its basedir.
RUN apt-get update \
 && apt-get install -y --no-install-recommends xz-utils \
 && mkdir -p /out \
 && tar -xJf /tmp/mysql.tar.xz -C /tmp \
      "${MYSQL_TARBALL}/bin/mysqld" "${MYSQL_TARBALL}/bin/mysqladmin" "${MYSQL_TARBALL}/bin/mysql" \
      "${MYSQL_TARBALL}/lib/private" "${MYSQL_TARBALL}/share" \
 && mv "/tmp/${MYSQL_TARBALL}" /out/mysql

# ── final: slim glibc base + the extracted server ────────────────────────────
FROM debian:bookworm-slim
# What `ldd` reports missing from the base: libaio1 + libnuma1 (mysqld), libncurses6 (mysql).
RUN apt-get update \
 && apt-get install -y --no-install-recommends libaio1 libnuma1 libncurses6 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 999 mysql \
 && useradd -u 999 -g mysql -d /var/lib/mysql -M -s /usr/sbin/nologin mysql \
 && install -d -o mysql -g mysql -m 0750 /var/lib/mysql
COPY --from=fetch /out/mysql /opt/mysql
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENV PATH=/opt/mysql/bin:$PATH

EXPOSE 3306
USER mysql:mysql
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mysqld"]
