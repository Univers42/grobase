---
title: Security overview
description: How Grobase keeps data isolated by default — owner-scoping and RLS per request, capability-scoped keys, managed secrets, and safe defaults.
section: Security
order: 1
---

# Security overview

Grobase is secure by default. The protections below are on from the first request,
not features you remember to enable later. The guiding rule is simple: isolation is
enforced **per request**, never inferred from connection state.

## Owner-scoping on every request

Every write is stamped with the caller's owner identity, and every read is filtered
to that owner before the query runs. You cannot read or modify another owner's rows
even if you know their ids, and you do not write any access-control code to get
this — it is the default behaviour of the data plane.

## Row-Level-Security policies

For sharing, roles and team access, layer declarative RLS policies on top of
owner-scoping. They are evaluated per request alongside the owner scope, so adding a
sharing rule never weakens the default isolation — it only widens access exactly
where you intend.

## Capability-scoped keys

API keys are capability masks: each grants an explicit, enumerable set of
permissions and nothing more. Issue narrow keys for narrow jobs — a read-only key
for a dashboard, a write key for an ingest worker. Keys are high-entropy tokens
verified with a fast hash, so verification is cheap and revocation is immediate.

## Managed secrets

Engine credentials, function secrets and signing keys are supplied out of band —
through a secret manager or the environment at start time — never committed to a
repository or baked into an image. Rotate them without redeploying application code.

## Safe, minimal defaults

Optional capabilities are off until you turn them on, so a fresh deployment starts
locked down. Behaviour changes are opt-in, which keeps a deployment predictable and
its attack surface as small as the features you actually use.

## Isolation that scales

Because scoping is per request, thousands of tenants can safely share one
connection pool — correctness never depends on which pool a request lands on. When
you need a larger blast-radius boundary, choose a stricter isolation model per
mount; the per-request guarantee holds either way.

## Next steps

See [Authentication](/docs/guides/authentication/) for identity and keys in
practice, and [Configuration](/docs/self-hosting/configuration/) for secrets and
isolation settings before production.
