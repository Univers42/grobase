---
description: Deploy/runtime service boundaries — fly=grobase owns all state, Vercel=stateless frontends, apps are contracts
---

# Service Boundaries (binding)

Full rule: [`wiki/architecture/service-boundaries.md`](../../wiki/architecture/service-boundaries.md).

The non-negotiable parts:

- **grobase (fly.io) owns ALL state** — the database (it manages Postgres directly; apps never touch raw
  storage), auth, OTP, realtime, files, anything beyond one request.
- **Vercel hosts only stateless frontends** + an optional **same-origin rewrite** to grobase (a forwarder,
  never a BFF, never a datastore). Frontends are pure clients — inert without grobase.
- **WebSocket goes browser → fly directly**, never through Vercel.
- **grobase contains zero app-specific code.** Each app is a declarative **provisioning contract**
  (`infra/config/contracts/<app>.json`) that grobase consumes to provision/seed/manage an isolated DB +
  emit the frontend's `PUBLIC_*` config. App = contract + frontend. Never hardcode an app into grobase.
- **vault42 is the motor, not a datastore** — it connects to grobase (GrobaseStore) as its store.
- **Two apps' databases never merge** — separate contract-provisioned databases + `read_scoped` + RLS +
  per-request owner-scoping.

Decision rule: touches state/auth/files/connections beyond one request → grobase; else → Vercel; unsure →
grobase. Never put fly secrets in Vercel env or vice-versa.
