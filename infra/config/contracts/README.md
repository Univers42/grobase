# Provisioning contracts

A **provisioning contract** is a declarative manifest that describes one app's backend
needs. `scripts/provision-contract.sh <contract.json>` is the GENERIC consumer: it reads a
contract and makes grobase create + own + seed that app's isolated database — replacing the
per-app `scripts/seed/*-tenant.sh` scripts. **grobase itself holds zero app-specific code**
(`grep -ri 'vault42|website|nimbus' src/` → nothing); every app specific lives here.

> "Provisioning contract" (this file) is distinct from vault42's Ed25519 **login contract**
> (issued by the contract authority). Same word, different concept.

App = **contract + frontend**. The frontend is a pure client: it owns no data and is inert
without grobase. Its config (`PUBLIC_*`) is **emitted** by the contract, never hand-written.

## Format

```jsonc
{
  "version": 1,
  "tenant": { "id": "<slug>", "name": "<display>", "plan": "free|essential|pro|max|enterprise",
              "owner_user_id": "system:<slug>" },

  "mounts": [                                  // each → its OWN database (never merged)
    { "name": "<mount-name>", "engine": "postgresql",
      "database": "<db-name>",                 // grobase CREATE DATABASEs this (the isolation boundary)
      "isolation": "shared_rls",               // db_per_tenant is not reconcilable; the DB is the boundary
      "read_scoped": true,                     // per-request owner-scoping (B never sees A's rows)
      "credentials": { "source": "docker_service", "host": "postgres", "port": 5432 }
      //            or { "source": "fly_secret", "dsn_env": "WEBSITE_PG_DSN" }  (prod)
    }
  ],

  "roles": [                                   // optional ABAC roles (provision StackSpec shape)
    { "name": "user", "policies": [ { "resource_type": "*", "resource_name": "*",
        "actions": ["select","insert","update","delete"], "effect": "allow",
        "conditions": { "owner_only": true } } ] }
  ],

  "api_keys": [ { "name": "default", "scopes": ["read","write"] } ],

  "schema": { "postgresql": "infra/config/contracts/<app>.schema.sql" },  // applied into the mount DB

  "seed":   { "script": "infra/config/contracts/<app>.seed.sh" },         // optional; gets BAAS_URL/API_KEY/TENANT_ID/PG_* env

  "frontend_config": {                          // emitted to the frontend; tokens resolved live
    "path": "<frontend>/.env",
    "vars": {
      "PUBLIC_GROBASE_URL": "${KONG_URL}",
      "PUBLIC_BAAS_KEY":    "${ANON_KEY}",
      "PUBLIC_API_KEY":     "${API_KEY}",
      "PUBLIC_TENANT_ID":   "${TENANT_ID}",
      "PUBLIC_DB_ID":       "${MOUNT_ID:<mount-name>}"
    }
  }
}
```

## Tokens (resolved by the provisioner at emit time)

| Token | Value |
|---|---|
| `${KONG_URL}` | the live gateway base URL |
| `${ANON_KEY}` | Kong public/anon consumer key (sent as `apikey`) |
| `${API_KEY}` | the minted app key (`mbk_…`, sent as `X-Baas-Api-Key`) — write-once; reused on re-run |
| `${TENANT_ID}` | the tenant slug |
| `${MOUNT_ID:<name>}` | the registered mount's id (the `/query/v1/<dbId>` path part) |

## What the provisioner does (idempotent)

1. discover the live stack (Kong/tenant-control URLs, service token, keys, PG creds) from the running containers;
2. `CREATE DATABASE` each mount's database if absent (the physical isolation boundary);
3. `POST /v1/provision` (HMAC-signed) the compiled StackSpec — tenant + key + roles + mount, find-or-ensure;
4. set `read_scoped=true` on each opted-in mount (authoritative `tenant_databases` UPDATE);
5. apply each engine's `schema` file into its database;
6. resolve the app key (fresh mint → reuse emitted → mint), emit the frontend config;
7. run the optional `seed` script.

Re-running a converged contract is a no-op (mount + key reused). Two apps' databases can never
merge: separate databases + `read_scoped` + RLS + per-request owner-scoping.

Run: `bash scripts/provision-contract.sh infra/config/contracts/<app>.json`
