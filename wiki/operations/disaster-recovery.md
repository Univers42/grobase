# Backup and disaster recovery runbook

## Supported baseline and ownership

The supported baseline is self-hosted Compose, not the retired Fly deployment.
The operator owns enabling schedules, remote storage, encryption-key custody,
alerts and recovery drills. Existing backups are not evidence of an active
production schedule or a contractual RPO/RTO.

`pg-backup` schedules `pg_dump` of **one database**, selected by
`PG_BACKUP_DATABASE_URL` (fallback `DATABASE_URL`), daily at 03:00 UTC by default,
and uploads it to MinIO. It does not automatically back up every PostgreSQL
database, cluster roles, other engines, or uploaded files. Create a separately
configured backup service/prefix for each authoritative database. Optional
physical/PITR modes have their own prerequisites; see [HA](../../deploy/ha/README.md).

Inventory every persistent store before calling the deployment protected:

| State | Mechanism / limitation |
|---|---|
| PostgreSQL databases | `pg-backup` per database; separately retain globals/roles and migration/configuration versions |
| Mongo, Cockroach, SQL Server | `scripts/ops/engine-backup.sh dump`; schedule separately, enable `age`, copy off-host |
| MySQL, MariaDB, SQLite, DynamoDB | Engine-native coherent backups or quiesced volume snapshots; not covered by `pg-backup` |
| Redis | Snapshot if authoritative; document reconstruction only if it truly is a cache |
| MinIO uploaded objects | Independent replication/versioned object backup, not the PostgreSQL dump |
| Vault/vault42 secrets and keys | Separate encrypted recovery copy and tested access; never store age private keys with the backup service |
| Functions and configuration | Retain durable function data, release/config versions, contracts and secret-recovery procedure |

`vault-seed`/`vault-restore` provide another engine-data export path. Their
coverage manifest must be checked; a local seed is not independent DR storage.

## Enable and monitor automatic PostgreSQL backups

1. Use an independently hosted S3-compatible MinIO endpoint via
   `PG_BACKUP_MINIO_ENDPOINT`, not the database host's local MinIO volume alone.
   Restrict bucket access, use HTTPS and object-store versioning/immutability.
2. Set `BACKUP_AGE_RECIPIENTS` to public recipients. Keep private identities
   offline/separately accessible, and test them during recovery.
3. Set `PG_BACKUP_MONITOR=1`, `PG_BACKUP_MAX_AGE_SECONDS=172800` (48 hours),
   `PG_BACKUP_SCHEDULE='0 3 * * *'`, and `PG_BACKUP_RETAIN_DAYS=14`. Adapt the
   age limit to the actual schedule; these defaults are configuration, not an SLA.
4. Build from current source (`make build`), then `make backup-now` to bootstrap
   a verified artifact before starting `make backups-start`.
5. The monitor reads every uploaded artifact back and compares bytes, uploads
   SHA-256 sidecars, and writes `monitor/last-success` only after completion.
   Its liveness check rejects missing/stale/future/malformed completion records
   as well as unreachable PostgreSQL/MinIO. `PG_BACKUP_MONITOR=0` preserves the
   old connectivity-only behavior. Successful uploads do **not** prove restore.
6. Use `make backup-status`; configure your external on-call monitor to alert on
   unhealthy/missing `pg-backup`, stale markers, job failures and storage capacity.
   Container health is a signal, **not automatic paging**. The public status
   service does not expose backup credentials or query private backup storage.
7. Retention deletes artifacts only after new verified uploads. Review bucket
   lifecycle policies and retain an independent longer-lived recovery copy for
   corruption discovered late. Do not rely solely on host volume snapshots.

## Logical recovery: isolate, verify, then cut over

1. Declare an incident; record detection time, affected stores and latest known
   good data time. Pause writes/background jobs before any production cutover.
2. Preserve original volumes and collect logs. Provision a **fresh isolated**
   database on compatible PostgreSQL; recover required roles/extensions from
   retained configuration. Never restore directly into the serving database.
3. Locate an off-host artifact and its `.sha256` sidecar. Restore with the
   backup image and a separate target URL injected securely:

   ```bash
   docker compose --profile backups run --rm \
     -e PG_BACKUP_MONITOR=1 -e RESTORE_CONFIRM=RESTORE \
     -e RESTORE_DATABASE_URL pg-backup restore logical/postgres-TIMESTAMP.dump
   ```

   For `.dump.age`, inject `BACKUP_AGE_IDENTITY_FILE` and mount the identity
   read-only into this **one-off** container. The checksum validates encrypted
   bytes before decryption. Monitored restore refuses a missing confirmation,
   an identical source/target URL or a missing/mismatched checksum. It cannot
   detect two differently spelled URLs pointing at the same database: isolation
   remains an operator responsibility. `pg_restore --clean` replaces target
   objects; `--exit-on-error` makes partial failures visible.
4. Check restored schemas/migrations, representative row counts and exact known
   records, auth, queries, realtime and file references. Restore other affected
   stores from their matching recovery set; a database-only drill proves only
   database recovery. Physical downloads are **not** automatic restore success.
5. Record recovery timestamp, elapsed time and missing data; run `make health`
   and smoke checks against the recovered backend. Only then switch connections,
   restart paused writers and verify real requests. Keep the old state intact
   until a rollback window expires.
6. If validation fails, do not cut over; preserve evidence and retry from an
   earlier valid recovery set. Roll back connections only to a validated state.

## Repeatable drills and truthful claims

- `make reliability-test`: local HTTP-to-status and durable-history tests plus
  deterministic command-adapter backup failure tests; no live database claims.
- `make recovery-drill`: isolated Docker PostgreSQL + MinIO, verified upload,
  monitored restore, exact recovered row, missing/stale completion rejection.
  The dedicated CI workflow runs this from the PR's source, not a prebuilt image.
- Monthly and after infrastructure/key changes, additionally restore a real
  **production off-host** artifact to isolated infrastructure. Record release,
  artifact/key, source data time, start/end, checks, achieved RPO/RTO and failures
  in your incident evidence store (never credentials). The CI fixture drill is
  not a production-sized failover measurement.
- No availability, full-cluster failover, RTO or RPO guarantee is introduced by
  these mechanisms. Enabling and observing them on real infrastructure and
  exercising every authoritative store is required before making commitments.
