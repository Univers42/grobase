---
title: Tiers
description: The five tiers — nano, basic, essential, pro, max — and how each is a capability mask over one codebase, never a separate product.
section: Self-hosting
order: 3
---

# Tiers

Grobase ships as five tiers, **nano → basic → essential → pro → max**. A tier is a
*capability mask* over a single codebase — it turns features, engines, and limits
on or off. It is never a fork and never a rewrite. Moving up a tier is a
deployment decision; your application and SDK calls stay exactly the same.

## The ladder

| Tier | Shape | For |
| --- | --- | --- |
| **nano** | Single 5 MB static binary, embedded datastore | A whole backend in one file; prototypes and small apps |
| **basic** | Container with the core data, auth and realtime API | A first production app on one engine |
| **essential** | More engines and capabilities enabled | A growing app that needs full-text/vector search, storage and functions |
| **pro** | Multi-project with per-tenant isolation | Serving many customers from one deployment |
| **max** | The full multi-tenant platform | A platform scaling toward thousands of tenants |

The exact, measured contents of each tier — RAM, engines, capabilities, limits —
are published on the [pricing page](/pricing/) and are the single source of truth.
What a tier advertises is what it measurably delivers.

## No-rewrite growth

Because every tier is the same code behind a different mask, you do not migrate
between them — you redeploy with more turned on. The 5 MB nano binary and the
10K-tenant platform expose the identical API and SDK. Code written on day one
against nano runs unchanged on max.

## Choosing a tier

Start at the smallest tier that covers what you need today. When you outgrow it —
more engines, more capabilities, more tenants — move up by flipping capabilities
on, not by rebuilding. See [Configuration](/docs/self-hosting/configuration/) for
the flags behind each capability.

## Next steps

Compare the measured contents on the [pricing page](/pricing/), or start small
with the [Quickstart](/docs/getting-started/quickstart/).
