---
title: Introduction
description: What Grobase is, and how one backend grows from a 5 MB binary to a multi-tenant platform without a rewrite.
section: Getting started
order: 1
---

# Introduction

Grobase is a self-hostable backend you run yourself: accounts, database, realtime,
files, search and functions over any of eight database engines — behind one
uniform API and one SDK.

## One codebase, every size

The same codebase ships as five tiers, from a single **5 MB binary** (the nano
edition) to a multi-tenant platform serving thousands of customers. Moving up a
tier is a deployment decision, never a migration project — your application code
and SDK calls stay the same.

## What you get on day one

- **Accounts and access** — sign-in, capability-scoped API keys, and
  owner-scoping enforced on every request so callers only see their own data.
- **Data over any engine** — PostgreSQL, MySQL, MongoDB, MSSQL, SQLite, Redis,
  DynamoDB and any HTTP/JSON source, all through one query API.
- **Realtime, storage, search and functions** — change-data-capture feeds,
  object storage, full-text and vector search, and server-side functions, built
  in rather than bolted on.

## How these docs are organised

- **Getting started** — [Quickstart](/docs/getting-started/quickstart/) to run the
  server and make your first calls, then [Core concepts](/docs/getting-started/concepts/)
  for the handful of ideas everything builds on.
- **Guides** — task-first walkthroughs:
  [Authentication](/docs/guides/authentication/),
  [Database CRUD](/docs/guides/database-crud/),
  [Realtime](/docs/guides/realtime/), [Storage](/docs/guides/storage/),
  [Functions](/docs/guides/functions/), and
  [Search](/docs/guides/search-fts-vector/).
- **Self-hosting** — [Run with Docker](/docs/self-hosting/docker/),
  [Configuration](/docs/self-hosting/configuration/), and
  [Tiers](/docs/self-hosting/tiers/).
- **Security** — the [security overview](/docs/security/overview/) of the
  default protections.

## Next steps

Pick the tier that fits what you are building on the
[pricing page](/pricing/), or browse the [guides](/docs/guides/) for
task-first walkthroughs.
