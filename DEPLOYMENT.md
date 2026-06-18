# Deployment — running Grobase BaaS in production

Operator guide for self-hosting. Companion docs: [QUICKSTART.md](QUICKSTART.md),
[SECURITY.md](SECURITY.md), [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 1. Sizing — tier → hardware (measured, not estimated)

Numbers are live measurements (`make bench-footprint`, regression-gated by `make verify-m32`).
Cloud costs assume Fly.io-class pricing (~$0.77/vCPU + ~$5/GB RAM per month).

| Tier | RAM | Disk (images) | Suggested VM | ~Infra cost |
|---|---|---|---|---|
| **binocle one/nano** | 2 MiB | 5–6 MB binary | 1 vCPU · 256 MB | ~$2/mo (<$1 idle) |
| **basic** | ~460 MiB | ~0.9 GB | 1 vCPU · 1 GB | ~$6/mo |
| **essential** | ~660 MiB | ~3 GB | 1 vCPU · 1–1.5 GB | ~$9/mo |
| **pro** | ~1.4 GiB | ~5.5 GB | 2 vCPU · 2 GB | ~$21/mo |
| **max** | ~3.5 GiB | ~11 GB | 2–4 vCPU · 4 GB | ~$41/mo |

basic/essential are RAM-bound, not CPU-bound, until they take real traffic.

## 2. Production overlay

The base compose is developer-friendly (DB ports exposed). Production applies the
hardening overlay — it strips direct database ports and adds resource limits +
restart policies:

```sh
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

With the Makefile orchestrator (preferred — picks profiles per tier):

```sh
make up PACKAGE=essential        # then apply the prod overlay for hardening
```

Also set in `.env` for production (full rationale in [SECURITY.md](SECURITY.md)):

```
SECURITY_MODE=max                 # external DB mounts must present verifiable TLS
PACKAGE_ENFORCEMENT=1             # tier limits actually enforced
KEY_HASH_PEPPER=<random 32 hex>   # HMAC pepper for API-key hashes
```

## 3. Backups and restore (run the drill BEFORE you need it)

The `pg-backup` service (profiles `backups`/`ops`) takes scheduled logical dumps
to MinIO/S3:

| Env | Default | Meaning |
|---|---|---|
| `PG_BACKUP_SCHEDULE` | `0 3 * * *` | cron — daily 03:00 |
| `PG_BACKUP_BUCKET` / `PG_BACKUP_PREFIX` | `backups` / `postgres` | destination |
| `PG_BACKUP_RETAIN_DAYS` | `14` | retention window |
| `PG_BACKUP_PHYSICAL` | `0` | `1` = physical/WAL-based instead of `pg_dump` |

```sh
# enable scheduled backups
docker compose --profile backups up -d pg-backup

make backup-now        # take one NOW (wraps `pg-backup once`)
make restore-verify    # prove a backup restores: dump→drop→restore→checksum
                       # on a SCRATCH db; never touches tenant data (gate m47)

# restore a specific artifact (downloads from MinIO to /restore, then applies)
docker compose run --rm pg-backup restore <key>
```

Manual path (no MinIO): `docker/services/postgres/tools/backup.sh` (pg_dump -Fc)
and `restore.sh`. `make restore-verify` runs the m47 gate, so "is my backup
actually restorable" is a one-command answer you can put on a schedule.

**Physical / WAL backups (D2):** `PG_BACKUP_PHYSICAL=1` switches to
`pg_basebackup` + WAL instead of logical dumps — the base Postgres already runs
`wal_level=logical` (the outbox slot needs it), which qualifies. Use it when
restore-time beats portability; logical dumps stay the cross-version-safe default.

**Connection pooling (D4):** `supavisor` (profiles `pooler`/`extras`, opt-in —
NOT default) is the transaction pooler for **managed/external Postgres** or very
high mount counts: point the control-plane DSNs at `:6543` instead of `:5432`.
It is deliberately not in the default path because `DATA_PLANE_SHARE_POOLS=1`
(C5) already makes pool count independent of tenant count — most deployments
never need a separate pooler. It is not wired into the Rust data plane (which
owns its pools directly).

**HA, honestly (D5):** this stack is single-node. For production-critical
Postgres, point `DATABASE_URL` at a managed/external Postgres (RDS, Cloud SQL,
Fly PG, Supabase) — every service follows the DSN, and the provider gives you
the replica/failover/PITR a self-hosted single node cannot. **That DSN swap is
the supported v1 HA answer**; self-hosted replica/failover (Patroni etc.) is
documented-advanced, not the default path.

## 4. Upgrades

```sh
# 1. read the release notes (GitHub Releases, tag baas-vX.Y.Z)
# 2. bump image tags / pull the new tree
git pull && make pull
# 3. restart through the orchestrator
make up PACKAGE=<your tier>
# 4. verify
make health && make verify-all
```

Migrations are idempotent and applied by `db-bootstrap` on start.

## 5. Image pin policy

- **First-party images** (the 16 suite images, binocle): exact version pins
  (`dlesieur/mini-baas-<svc>:1.0.0` on Docker Hub).
- **Third-party images**: pinned at least to major (`postgres:16-alpine`,
  `mongo:7`, `redis:7-alpine`) or exact (`kong:3.8`, `supabase/gotrue:v2.188.1`).
- Want digest-level reproducibility? `scripts/pin-digests.sh` resolves every
  `FROM` to its digest.

## 6. Kubernetes (beta)

A generated Helm chart lives at `deploy/helm/mini-baas` (values overlays per
edition: lean/query/realtime/analytics/prod/full), validated by `make verify-m21`.

```sh
kubectl create configmap mini-baas-env --from-env-file=.env
kubectl create secret generic mini-baas-secrets --from-env-file=.env
helm install mini-baas deploy/helm/mini-baas -f deploy/helm/mini-baas/values-prod.yaml
```

Honest limits today: no ingress/PVC/secret templating (you create them, as above);
resource limits are converted from compose budgets. Compose is the primary
production surface for v1.0; the chart is for evaluation.

## 7. Secrets lifecycle

- `make env` generates `.env` (chmod 600, never committed; `FORCE=1` to regenerate).
- `make secrets-rotate GROUP=jwt|tenant-dsn|all` rotates the JWT secret family.
- Vault is OPTIONAL (profile `control-plane`): `make vault-init`, `make vault-rotate GROUP=…`.
- `make check-secrets` scans the tree for accidental hardcoded secrets.
