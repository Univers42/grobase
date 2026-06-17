# Grobase managed-cloud flags — the single flip point + promotion ladder

> **Track-B B7.1.** This directory is the ONE authoritative place to flip the
> B1–B7 managed-cloud features ON per environment. Plan:
> `apps/baas/.claude/plans/managed-cloud-enterprise.md` (slice B7.1).

## What this is (and what it deliberately is NOT)

- **It is** an opt-in env manifest (`flags.env.example`) listing every cloud
  behaviour flag, all OFF, plus this promotion-ladder doc.
- **It is NOT** a change to `docker-compose.yml` or `.env`. The default stack
  never reads this directory. Every flag already defaults OFF *inside the
  service code* (Go `envBool`, Rust `config.rs`), so the default build / compose
  / env stay **byte-parity** with the OSS self-host edition. This manifest only
  makes the cloud-canonical values explicit and gives an operator one file to
  source per environment.

## Inspect

```bash
make cloud-flags-print     # from apps/baas/mini-baas-infra/ — just cats the manifest, no behaviour
```

## Single source of truth for flag NAMES

The names in `flags.env.example` are exactly the env vars the services read.
Verify before trusting this doc (a flag with no consumer is a parity lie):

```bash
grep -rn 'METERING_ENABLED\|QUOTA_ENFORCEMENT\|BILLING_ENABLED\|TENANT_SELFSERVE_ENABLED\|TENANT_OBS_ENABLED\|TENANT_BACKUP_ENABLED' go/control-plane
```

`SPEND_CAPS_ENABLED` and `ABUSE_GUARD_ENABLED` are **fully built and
gate-proven** (B7.8 → `internal/spendcap` wired in `cmd/orchestrator`, gate m89;
B7.9 → `internal/abuseguard` mounted in `cmd/tenant-control`, gate m90).
Flipping either ON enables real behaviour (a `spend:over` set / a `/v1/abuse/*`
surface + `tenant:suspended` set); they are not no-ops. The all-cloud-ON rung is
captured in `config/cloud/flags.env.cloud`.

## How to turn a feature ON for an environment

```bash
# 1. copy the manifest for the target env
cp config/cloud/flags.env.example config/cloud/flags.staging.env

# 2. flip ONLY the rung(s) you are promoting (see the ladder below)

# 3. merge into the stack env (or hand the values to your secrets tool)
cat config/cloud/flags.staging.env >> .env

# 4. recreate the control plane so the new env takes effect
make up EDITION=prod
```

`flags.<env>.env` files are environment-specific and should be **gitignored /
fed from your secrets store** — never commit a populated one (it carries
`STRIPE_API_KEY` etc.). Only `flags.env.example` (all-OFF, no secrets) is
tracked.

## The promotion ladder — staging → canary → prod

Promote **one rung at a time, in this order**. Never enable enforcement
(402s, spend caps, abuse suspends) before it has shadowed and warned. A surprise
402 or a wrongful suspend is a production incident, not a config tweak.

| Rung | staging | canary (1 internal tenant) | prod | Flags flipped |
|------|---------|-----------------------------|------|---------------|
| **R0 · baseline (OSS parity)** | all OFF | all OFF | all OFF | — |
| **R1 · observe** | ON | ON | ON | `METERING_ENABLED=1`, `METERING_INGEST=1`, `DATA_PLANE_METERING=1`, `TENANT_OBS_ENABLED=1`, `DATA_PLANE_TENANT_OBS=1` |
| **R2 · self-serve** | ON | ON | ON | `TENANT_SELFSERVE_ENABLED=1`, `TENANT_BACKUP_ENABLED=1` |
| **R3 · quota shadow** | `QUOTA_STAGE=shadow` | shadow | shadow | metering computes overage, logs only — **no 402** (`QUOTA_ENFORCEMENT=0`) |
| **R4 · quota warn** | `QUOTA_STAGE=warn` | warn | shadow | warn header / soft signal, still **no 402** |
| **R5 · quota enforce** | `QUOTA_STAGE=enforce` + `QUOTA_ENFORCEMENT=1` | enforce | warn→enforce | the first rung that can return **402** |
| **R6 · billing** | `BILLING_ENABLED=1` (Stripe TEST key) | TEST key | LIVE key | Stripe meter events; requires `STRIPE_API_KEY` + `BILLING_METER_*` |
| **R7 · spend caps / abuse** | `SPEND_CAPS_ENABLED=1` (+`SPEND_RATE_*`), `ABUSE_GUARD_ENABLED=1` (+`ABUSE_VELOCITY_MAX`) | canary | prod | the cost-runaway + signup-abuse GO-LIVE gates (B7.8/B7.9, gates m89/m90); the control-plane sets `spend:over`/`tenant:suspended` |

### Invariants the ladder must keep congruent

- **Metering is the master.** `METERING_ENABLED` must be ON before quota/billing
  do anything — the code ANDs each with it (`metering/billing.go`,
  `metering/quotaguard.go`). Enabling quota/billing with metering OFF is a no-op,
  not an error, but it is a misconfiguration; promote R1 first.
- **`QUOTA_STAGE` and `QUOTA_ENFORCEMENT` stay congruent.** `QUOTA_STAGE` is the
  human-readable staged dial (shadow/warn/enforce); `QUOTA_ENFORCEMENT` is the
  hard boolean the guard reads today. `stage=enforce` ⇔ `QUOTA_ENFORCEMENT=1`;
  shadow/warn ⇔ `QUOTA_ENFORCEMENT=0`.
- **Billing needs its credentials or it refuses to start.** With
  `BILLING_ENABLED=1` but `STRIPE_API_KEY` / `BILLING_METER_*` unset, the
  reporter errors loudly (by design — see `metering/billing.go`). Set the secrets
  via your secrets tool, never in a committed file.
- **GO-LIVE gate (plan critic):** public signup (B7.7) MUST NOT ship before R7
  spend caps + abuse guard + the API-version contract (B7.11). R7's control-plane
  halves are built + gate-proven (m89/m90); the data-plane reject halves
  (`DATA_PLANE_SPEND_CAPS` / a suspend reader) are a separate slice, so prod stays
  at R6 + the control-plane R7 guards for internal/invited tenants until the
  data-plane halves land. The full all-ON local rung is `flags.env.cloud` (proven
  end-to-end by m94).

## Parity statement

With this directory **absent or all-OFF**, the stack is byte-identical to the
OSS edition. The matrix gate (plan risk #1) boots the all-OFF stack and diffs it
against the committed baseline. This file changes nothing on its own — it is
read only when an operator explicitly sources a `flags.<env>.env` into `.env`.
