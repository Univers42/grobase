---
title: Core concepts
description: Projects, engines, the uniform API, owner-scoping and RLS, capabilities, and tiers — the handful of ideas the whole platform is built on.
section: Getting started
order: 3
---

# Core concepts

Grobase is built on a small set of ideas. Learn these once and every feature —
database, realtime, storage, search, functions — behaves the way you expect.

## Projects

A project is an isolated namespace. It owns its data, its keys, and its
configuration. On the platform tiers a project maps to a tenant; on the single
binary it is simply your application's space. The same SDK call works in both.

## Engines

Grobase speaks **eight database engines** — PostgreSQL, MySQL, MongoDB, MSSQL,
SQLite, Redis, DynamoDB, and any HTTP/JSON source — through one query layer. A
data source you connect is called a *mount*. You choose the engine that fits the
data; your application code does not change when you do.

This is *engine-agnostic by construction*: a behaviour is only considered correct
when it works the same across every engine, not just one.

## The uniform API

There is one API surface — `select`, `insert`, `update`, `delete`, aggregate,
realtime subscribe — and one SDK. Switching the engine behind a mount, or moving
from the nano binary to the multi-tenant platform, never changes the calls you
write. One backend, any frontend, no per-project server code.

## Owner-scoping and RLS

Access control is enforced **per request**, not by trusting connection state.
Every write is stamped with the caller's owner identity; every read is filtered to
rows that caller owns. Row-Level-Security policies extend this with declarative
rules. Because scoping is evaluated on each request, thousands of tenants can
safely share one connection pool — isolation never depends on which pool you land
on.

## Capabilities and keys

An API key is a **capability mask**: it grants a specific, enumerable set of
permissions (read, write, manage, and more). Keys are high-entropy secrets
verified with a fast hash, so issuing and revoking them is cheap and instant.

## Tiers

The same codebase ships as tiers — **nano → basic → essential → pro → max**. A
tier is a capability mask over the platform: it turns features and limits on or
off, it does not fork the code. Moving up a tier is a deployment choice; your
application and SDK stay identical. See [Tiers](/docs/self-hosting/tiers/) for what
each one includes.
