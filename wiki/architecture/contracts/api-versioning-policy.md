# Grobase API versioning & deprecation policy

> **Track-B B7.11** (`apps/baas/.claude/plans/managed-cloud-enterprise.md`). This
> is the durable contract for how the Grobase HTTP API evolves: how versions
> coexist, how a route is deprecated (RFC 8594), the skew window clients can rely
> on, and how the SDKs are regenerated. It **blocks Enterprise GA** — a B2B buyer
> needs a written, enforceable promise that an SDK regen will not silently break
> their integration.

## 1. Versioning model

- The API is **path-versioned**: every public route is prefixed `/<surface>/v1`
  (`/rest/v1`, `/query/v1`, `/data/v1`, `/auth/v1`, `/storage/v1`, …). The
  version is the segment after the surface name.
- A **major version** (`v1` → `v2`) is the only place a breaking change lands.
  Within a major version we only make **additive, non-breaking** changes (new
  fields, new optional params, new routes). Removing a field, renaming a param,
  changing a status-code contract, or tightening validation is a **breaking
  change** and requires a new major.
- `/v2` **coexists** with `/v1` on the same gateway — a new major is a new set of
  routes, not a flag-day cutover. Both serve real traffic for the whole skew
  window below.

### What is NOT a breaking change (safe within a major)

Adding response fields · adding optional request fields · adding a new route ·
adding a new enum value a client already treats as opaque · relaxing validation ·
performance/latency changes. Clients MUST ignore unknown response fields
(forward-compatibility contract) — SDKs are generated to do so.

## 2. Version-skew window

| Stage | Guarantee |
|-------|-----------|
| **Active** | the current major (`/v1`) — full support, the default the SDKs target. |
| **Deprecated** | a route/major announced for retirement. It keeps working and serving real responses, but every response carries the RFC 8594 lifecycle headers (§3). |
| **Sunset** | the instant in the `Sunset` header. After it, the route MAY return `410 Gone`. It is not removed before this instant. |

- **Minimum deprecation window: 6 months** between the deprecation announcement
  (first `Deprecation` header shipped) and the `Sunset` instant. Enterprise
  contracts may extend this; never shorten it.
- **At most two majors are Active-or-Deprecated at once.** When `/v2` ships,
  `/v1` becomes Deprecated; `/v1` must reach Sunset before a `/v3` could
  deprecate `/v2`.

## 3. The deprecation signal (RFC 8594)

A deprecated route stamps these response headers (and ONLY a deprecated route —
see the parity guarantee in §5):

| Header | Value | Meaning |
|--------|-------|---------|
| `Deprecation` | `true` (or an RFC 9651 date) | the resource is deprecated. |
| `Sunset` | an HTTP-date (RFC 1123), a **valid future instant** | earliest removal time. |
| `Link: …; rel="deprecation"` | URL of the migration guide | where to read how to migrate. |
| `Link: …; rel="successor-version"` | URL of the replacement (e.g. `/v2`) | what to move to. |

This is implemented as an **opt-in, route-scoped** Kong `response-transformer`
overlay: `docker/services/kong/conf/deprecation.overlay.yml.example`. It is NOT
in the default `kong.yml`. Marking a route deprecated is a deliberate operator
action; until then no route carries these headers.

Clients SHOULD surface a one-time warning when they see `Deprecation` and plan
migration before `Sunset`. SDKs log a deprecation warning automatically.

## 4. SDK regeneration contract

- The SDKs are **generated from the OpenAPI spec** (see `m57-sdk-openapi.sh`).
  An SDK regen MUST NOT introduce a breaking change against an Active major —
  the OpenAPI diff is the gate: additive-only within `/v1`.
- A new major (`/v2`) is published as a **new SDK namespace / module path**, not
  an in-place overwrite of the `/v1` client. A consumer upgrades deliberately by
  switching the import, never by a transitive dependency bump.
- Generated clients **ignore unknown response fields** (§1) and **emit the
  deprecation warning** when a `Deprecation` header is present (§3).
- Mobile SDKs (Swift/Kotlin) follow the same contract; a regen that would break
  a published app store binary is a major.

## 5. Parity guarantee (kernel rule #5)

The default build / compose / `kong.yml` mark **no** route deprecated, so the
default proxy emits **zero** `Sunset`/`Deprecation` headers — byte-identical to
today. The contract is enforced by an additive overlay applied per-route only
when a route is genuinely on the deprecation timeline. The gate
`scripts/verify/m91-api-version-contract.sh` proves three arms:

1. **POSITIVE** — a route marked deprecated returns `Sunset` + `Deprecation`
   with a valid future date.
2. **REJECT (load-bearing)** — a NON-deprecated route returns NO such headers
   (no accidental global stamping).
3. **PARITY** — with the overlay absent, all routes are byte-identical.

## 6. Operational checklist to deprecate a route

1. Ship `/v2` of the surface (coexists with `/v1`).
2. Write the migration guide; publish the `rel="deprecation"` + `successor-version`
   URLs.
3. Apply the route-scoped overlay (`deprecation.overlay.yml.example`) with a
   `Sunset` ≥ 6 months out.
4. Regenerate SDKs targeting `/v2` (new namespace); keep `/v1` SDK published.
5. Track adoption; notify remaining `/v1` callers (per-tenant obs / B5 surfaces
   the version in use).
6. At `Sunset`, switch `/v1` to `410 Gone`, then remove after a grace period
   (subject to the shadow→parity→cutover→delete discipline, kernel rule #3).
