# A subnet-wide private-range allowlist for the dial guard under enforce is out of scope

- Decided: 2026-10-30 · by devil (G2 dial-guard ruling)
- Holds while: tenant DSNs and platform services share docker networks and arrive with the same provenance

## The concept

Set `DATA_PLANE_DIAL_ALLOW_CIDRS` to the docker subnets that show up in the 24 h shadow log, so the live seeded mounts keep working when the guard flips to enforce.

## Why not

- Every live mount arrives as `inline_dsn` and is therefore Tenant (`src/data-plane-router/crates/data-plane-pool/src/resolver.rs:194-203`). The guard cannot tell a seeded mount from a tenant's mount.
- The same subnet holds the platform postgres, the pool redis, Vault and adapter-registry. A /16 entry lets any tenant inline DSN reach all of them, which is the SSRF the guard exists to stop.
- The plan of record requires "an explicit per-tenant allowlist, no blanket block" (`wiki/architecture/multidb-holistic.md:212-213`).

## Prior requests

- 2026-10-30 (G2 dial plan, step 7): "or the CIDR list set to the docker subnets that show up".

## Reopen when

Mount provenance comes from a signed, registry-stored platform/tenant flag rather than from the resolver step, so platform mounts skip the guard and tenants never need the subnet.
