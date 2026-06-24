---
title: Configuration
description: How Grobase is configured — environment variables, secrets, mounts, and the capability flags that shape a deployment.
section: Self-hosting
order: 2
---

# Configuration

Grobase is configured through environment and a small set of files. The defaults
are safe and minimal; you opt into capabilities deliberately, so a fresh
deployment starts locked down rather than wide open.

## Core settings

| Setting | Purpose |
| --- | --- |
| Data directory | Where the embedded datastore and local files live |
| Listen address | The host and port the API binds to |
| Public URL | The externally reachable origin, used for links and callbacks |

## Mounts

A **mount** connects Grobase to a database engine. Each mount names an engine and
its connection details; once mounted, your application queries it through the same
uniform API. Define mounts in configuration so credentials never appear in
application code.

## Secrets

Secrets — engine credentials, function secrets, signing keys — are supplied out of
band, never committed to a repository or baked into an image. Provide them through
your secret manager or the environment at start time, and rotate them without
redeploying application code.

## Capability flags

Optional capabilities are **off by default**. You turn on exactly what a
deployment needs — additional engines, realtime, functions, managed-cloud
features — by flipping a flag. Leaving a flag off keeps the deployment minimal and
behaviour predictable; turning one on is the only thing that changes it. This is
how one codebase serves everything from the 5 MB binary to a multi-tenant
platform without a rewrite.

## Isolation model

Where many projects share one deployment, choose an isolation model per mount —
from a shared pool with per-request scoping (the most efficient) up to fully
separate pools. Isolation is enforced per request regardless, so the choice trades
resource use against blast-radius, never correctness.

## Next steps

Pick the capability set that matches your plan in
[Tiers](/docs/self-hosting/tiers/), and review the
[Security overview](/docs/security/overview/) before going to production.
