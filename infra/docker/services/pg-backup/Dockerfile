# Postgres backup container.
#
# - Nightly logical backup with pg_dump (custom format, compressed).
# - Optional weekly physical base backup with pg_basebackup when
#   PG_BACKUP_PHYSICAL=1 and the postgres server has wal_level=replica.
# - Uploads to a MinIO bucket via `mc` and rotates older artifacts.
#
# - Point-in-time recovery (C4b) when PG_BACKUP_PITR=1: postgres ships WAL via the
#   `archive-wal` mode (archive_command target), and `pitr-restore` rebuilds a
#   PGDATA from a base + replays WAL to recovery_target_time. PITR is OFF by
#   default, so the default image behaves exactly like the whole-cluster logical
#   backup it always did.
#
# Run modes:
#   docker run pg-backup                       -> long-running cron loop
#   docker run pg-backup once                  -> single dump now (CI / on-demand)
#   docker run pg-backup restore X             -> download artifact X to /restore
#   docker run pg-backup archive-wal %p %f     -> ship one WAL segment (PITR, PG_BACKUP_PITR=1)
#   docker run pg-backup pitr-restore B T      -> base+WAL replay to time T (PITR, PG_BACKUP_PITR=1)
# nosemgrep: dockerfile.security.missing-user.missing-user -- internal-only backup sidecar
# (not network-facing) needing root for pg_basebackup/PITR fs paths + the backup volume;
# hardening to a dedicated user tracked in wiki/security-audit.md.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/lib/postgresql/16/bin:$PATH

# postgresql-client (16 from PGDG matches the postgres image), mc, dcron.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget gnupg lsb-release cron tini \
      curl bash coreutils && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client-16 && \
    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc \
      -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc && \
    rm -rf /var/lib/apt/lists/*

COPY scripts/ /opt/pg-backup/
RUN chmod +x /opt/pg-backup/*.sh

WORKDIR /opt/pg-backup

ENV PG_BACKUP_SCHEDULE="0 3 * * *" \
    PG_BACKUP_BUCKET="backups" \
    PG_BACKUP_PREFIX="postgres" \
    PG_BACKUP_RETAIN_DAYS=14 \
    PG_BACKUP_PHYSICAL=0 \
    PG_BACKUP_PITR=0 \
    PG_BACKUP_TIER="essential"

HEALTHCHECK --interval=60s --timeout=10s --start-period=15s --retries=3 \
  CMD ["/opt/pg-backup/entrypoint.sh", "liveness"]

# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint -- backup sidecar, see FROM
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/pg-backup/entrypoint.sh"]
# nosemgrep: dockerfile.security.missing-user.missing-user -- backup sidecar, see FROM
CMD ["loop"]
