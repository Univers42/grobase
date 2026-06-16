# syntax=docker/dockerfile:1
# File: docker/services/cockroach/Dockerfile
#
# Self-built CockroachDB: we download the upstream STATIC release TARBALL
# (a binary artifact, NOT the cockroachdb/cockroach image) from Cockroach
# Labs' official binaries CDN and extract `cockroach` + its bundled spatial
# libs (lib/libgeos*.so) onto a slim base. Tag matches the compose pin v24.3.5.
#
# Base note: the official cockroach linux build is glibc-linked
# (interpreter /lib64/ld-linux-x86-64.so.2 — it needs libc/libm/libresolv and
# auto-loads lib/libgeos_c.so), so it CANNOT run on Alpine/musl. We therefore
# use debian:bookworm-slim — a lightweight glibc *base OS* (~30 MB, allowed by
# the 42-Inception rule, which permits a slim base / extracted upstream binary).
#
# The `start-single-node …` command and the `cockroach sql … SELECT 1`
# healthcheck both come from docker-compose.yml.

# ── builder: fetch + extract the static release tarball ──────────────────────
FROM alpine:3.21 AS build
ARG CRDB_VERSION=v24.3.5
# binutils → `strip` the ~600 MB unstripped Go binary (drops debug_info; the
# binary still runs, it just loses symbol names in panic traces). This is what
# keeps the slim image well under the fat upstream image.
RUN apk add --no-cache wget tar binutils \
 && wget -q -O /tmp/cockroach.tgz \
      "https://binaries.cockroachdb.com/cockroach-${CRDB_VERSION}.linux-amd64.tgz" \
 && mkdir -p /out/cockroach \
 && tar -xzf /tmp/cockroach.tgz -C /tmp \
 && cp /tmp/cockroach-${CRDB_VERSION}.linux-amd64/cockroach /out/cockroach/cockroach \
 && cp -r /tmp/cockroach-${CRDB_VERSION}.linux-amd64/lib /out/cockroach/lib \
 && strip --strip-unneeded /out/cockroach/cockroach \
 && strip --strip-unneeded /out/cockroach/lib/*.so

# ── final: slim glibc base + the extracted binary + spatial libs ─────────────
FROM debian:bookworm-slim
# Create the user FIRST so the big COPY can set ownership inline — a separate
# `chown -R` would re-write all ~208 MB into a second layer (doubling the image).
RUN groupadd -g 1001 cockroach \
 && useradd -u 1001 -g cockroach -d /cockroach -M cockroach
# cockroach auto-discovers libgeos in <bin_dir>/lib; keep the official layout.
COPY --from=build --chown=1001:1001 /out/cockroach /cockroach
RUN ln -s /cockroach/cockroach /usr/local/bin/cockroach \
 && install -d -o cockroach -g cockroach /cockroach/cockroach-data

EXPOSE 26257 8080
USER 1001:1001
WORKDIR /cockroach

# Healthcheck mirrors compose (cockroach sql … SELECT 1); kept here for parity.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD cockroach sql --insecure --host=127.0.0.1:26257 -e "SELECT 1" || exit 1

# No ENTRYPOINT: compose's `command: start-single-node …` replaces this CMD
# wholesale, so there is no doubled `cockroach`.
ENTRYPOINT ["cockroach"]
CMD ["version"]
