---
title: Engine-agnostic by construction
description: Grobase speaks eight database engines behind one uniform API — and treats engine-agnosticism as a rule, not a feature. A fix that works for one engine but breaks another is not done.
date: 2026-06-10
author: The Grobase team
tags:
  - architecture
  - engineering
  - product
---

# Engine-agnostic by construction

Plenty of backends support more than one database. Often that support is uneven:
one engine is the real product and the rest are adapters that lag behind, missing
features and quietly behaving differently. Grobase treats engine-agnosticism as a
**construction rule** instead — a fix that works for one engine but breaks another
is not finished.

## Eight engines, one uniform API

The data plane speaks eight engines: PostgreSQL, MySQL, MongoDB, MSSQL, SQLite,
Redis, an HTTP/JSON federation adapter, and DynamoDB. Your application does not
address them differently. You call the same uniform API — read, write, search,
aggregate, subscribe — and Grobase translates that to whichever engine your data
lives in.

Point the platform at the database your data is already in. There is no per-engine
rewrite of your app and no migration of your data to a blessed store.

## Why "by construction" matters

It is easy to claim multi-engine support and hard to keep it honest as the product
grows. The discipline that keeps Grobase honest is simple to state: a change is
only complete when it holds across every adapter. A behaviour that is correct on
Postgres but diverges on the other seven is a regression, not a feature.

That rule has teeth because the most important guarantees are enforced uniformly:

- **Owner-scoping is per request, on every engine.** Isolation is not a property
  of one favoured adapter; it is applied the same way to all of them.
- **The API surface does not fork.** You do not learn a different dialect when you
  switch the engine underneath a mount.

## The HTTP adapter: anything can be a table

One adapter deserves a special mention. The HTTP/JSON connector lets you federate
an external service as a mount, so a remote API reads like another table through
the same uniform interface. The agnostic design is not limited to databases you
host — it reaches services you call.

## The honest trade-off

Being engine-agnostic has a real cost: Grobase exposes the capabilities the
engines share through one API, rather than surfacing every proprietary feature of
every engine. That is a deliberate choice in favour of portability and a single,
learnable surface. Where an engine offers something special, you still have your
database; where you want one API across all of them, that is what Grobase is for.

As always, the behaviour is measured on the real stack across the engines, not
asserted. See [Connectors](/resources/connectors/) for the full engine list, or
the [guides](/docs/guides/) to query across them.
