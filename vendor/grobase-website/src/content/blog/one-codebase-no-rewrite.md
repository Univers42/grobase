---
title: From a 5 MB binary to a 10K-tenant platform — one codebase
description: How Grobase grows from a single static binary to a multi-tenant platform without a rewrite — the same SDK, the same API, the same code, all the way up.
date: 2026-06-11
author: The Grobase team
tags:
  - architecture
  - scaling
  - product
---

# From a 5 MB binary to a 10K-tenant platform — one codebase

The usual story of a backend is a sequence of rewrites. You start with something
small and simple, outgrow it, and migrate to something heavier — re-learning an
API, re-porting your data, and re-testing everything along the way. Grobase is
built so that story never happens.

## The same code at every size

Grobase ships as **one codebase**. A prototype runs as a 5 MB single binary on a
spare machine. A product runs as a multi-tenant platform serving thousands of
tenants. The difference between those two is configuration — editions, engines
and isolation models — not different software and not a different API.

You graduate between tiers. You never migrate off the platform.

## Why isolation is per-request, not per-pool

The key design decision that makes this possible is where isolation lives. In
Grobase, owner-scoping is enforced **per request**, not by the state of a
connection pool. A query carries who is asking, and the data plane scopes the
result to that caller every time.

Because isolation is not tied to pool state, many tenants can share the same
connection pool safely. That is what lets the data plane collapse a large number
of tenants onto a small, shared footprint instead of paying for a pool per
tenant. The same mechanism that keeps one developer's prototype data private is
the mechanism that keeps ten thousand tenants apart.

## You choose the isolation model

Multi-tenancy is not one-size-fits-all, so Grobase offers a choice of isolation
models per mount rather than forcing a single trade-off. You pick where you want
to sit on the spectrum between maximum sharing and maximum separation, mount by
mount — and you can change your mind without changing your application code.

## Measured, not asserted

We do not ask you to take the scaling story on faith. The footprint, the latency
and the multi-tenant behaviour are benchmarked on the real stack, and every
figure on this site is reproducible from a make target. When we say the data
plane holds many tenants in a small amount of memory, that number came from a
run, not a slide.

## What it means for you

Start tiny without worrying that you are choosing a dead end. The decision to use
Grobase for a weekend prototype is the same decision that carries you to a
production multi-tenant platform — because it is the same backend, the whole way
up.

See the [pricing](/pricing/) to find the tier that matches what you are building,
or read [Connectors](/resources/connectors/) for how the engines fit underneath.
