# Licensing

Grobase uses an **open-core** model. Different parts of this repository are under
different licenses. This file is the authoritative map; the per-area `LICENSE`
files are the legal text.

> **Not legal advice.** `LICENSE-ENTERPRISE.md` and `CLA.md` are templates. Have a
> lawyer review them before you sell a commercial license, accept your first
> external contribution, or launch the managed cloud. See `HUMAN-ATOMS.md`.

## The short version

| You want to…                                              | You can, under… |
| --------------------------------------------------------- | --------------- |
| Read, fork, self-host, modify the core                    | AGPLv3 (free)   |
| Run a **modified** Grobase as a network service           | AGPLv3 — **but you must publish your source** |
| Run a modified Grobase **without** publishing your source | a **commercial license** (contact us) |
| Use the official SDKs in any app, closed or open          | MIT (free)      |
| Use the **enterprise** features (SSO, SCIM, audit, CMEK…) | a **commercial license** (paid) |

## What's under what

### Core — AGPL-3.0-only

The server, control, and data planes are licensed **GNU Affero General Public
License v3.0** (`LICENSE`, SPDX `AGPL-3.0-only`). This covers everything in the
repo **except** the SDKs and the enterprise packages listed below.

AGPLv3 is real, OSI-approved open source. Its one teeth-bearing clause: if you run
a **modified** version as a network-accessible service, you must offer your users
the complete corresponding source of your modified version. That is what stops a
competitor from taking Grobase, improving it privately, and reselling it as a
closed hosted service — they either keep their changes open, or they buy a
commercial license from us.

We retain copyright (every contributor signs the `CLA.md`), so we — and only we —
can **dual-license**: offer a paid commercial license that waives the AGPL
copyleft obligation for customers who can't comply with it.

### SDKs — MIT

The client SDKs are intentionally permissive so anyone can build on them freely
(maximum adoption is the goal for a client library):

- `sdks/js/` (`@grobase/js`) — MIT (`sdks/js/LICENSE`)
- `sdks/python/`, `sdks/kotlin/`, `sdks/swift/`, `sdks/dart/` — MIT

Using an SDK to talk to a Grobase server does **not** put your application under
AGPL. The AGPL applies to the *server* you run, not to clients that call it.

### Enterprise features — Grobase Enterprise License (commercial)

These packages are **NOT** under AGPL. They are source-available for evaluation
only and require a paid commercial agreement to use in production. Each directory
carries its own `LICENSE` pointer; the full terms are in `LICENSE-ENTERPRISE.md`
(SPDX `LicenseRef-Grobase-Enterprise`).

| Package (`src/control-plane/internal/…`) | Feature |
| ---------------------------------------- | ------- |
| `orgs`            | Organization model + RBAC (D1) |
| `sso`             | Enterprise SSO / OIDC (D2a) |
| `scim`            | SCIM 2.0 user provisioning (D2b) |
| `passkeys`        | Passkeys / WebAuthn (D2c) |
| `ipguard`         | IP allowlisting (D2e) |
| `audit`           | Tamper-evident audit chain (D3) |
| `compliance`      | SOC2-lite evidence + compliance posture (D4.1) |
| `erase`           | Hard-erase / right-to-be-forgotten (D4.4) |
| `export`          | Tenant data export (D4.3) |
| `telemetryexport` | Tenant telemetry export |
| `trust`           | Trust center (D4.6) |
| `cmek`            | CMEK / BYOK envelope encryption (m123) |

### What stays in the open core (AGPL)

Deliberately **not** enterprise — these drive developer adoption and remain AGPL:
`branching` (DB branching, E·m113), `push` (push/messaging, E·m114), `webhooks`,
and every Track-B managed-cloud component (metering, quota, billing, self-serve,
per-tenant obs, backup). The cloud product is sold as *hosting + support*, not by
locking these behind a license.

## Moving the open-core line

The split is enforced by the per-directory `LICENSE` files, not by code. To move a
package across the line:

1. Add or remove the package's directory `LICENSE` pointer.
2. Update the table in this file.
3. Update `scripts/verify/` if a gate asserts the license boundary.

## SPDX summary

```
Core            AGPL-3.0-only
SDKs            MIT
Enterprise      LicenseRef-Grobase-Enterprise
```

## Contributing

All contributions are inbound under the `CLA.md` so the dual-licensing model holds.
By opening a PR you agree to it.
