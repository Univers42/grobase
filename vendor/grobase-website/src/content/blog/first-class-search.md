---
title: First-class full-text and vector search
description: Search is not a bolt-on in Grobase — full-text and vector search are part of the same uniform query API, available across the engines from the smallest binary up.
date: 2026-06-12
author: The Grobase team
tags:
  - search
  - engineering
  - product
---

# First-class full-text and vector search

Most backends treat search as an afterthought — a separate service you stand up,
sync to, and keep in step with your real data. Grobase takes the other path:
search is part of the **same uniform query API** you already use for reads,
writes and aggregates.

## One API, not a second system

When search lives outside your database, you inherit a second system to operate:
its own indexing pipeline, its own failure modes, its own data that can drift
from the source of truth. Grobase removes that split. You query your data and you
search your data through one SDK call shape — the engine does the work behind the
uniform API.

That means there is no extra service to run for search to exist. The same backend
that serves your CRUD serves full-text and vector queries.

## Full-text and vector, side by side

Two kinds of search matter for modern apps, and Grobase exposes both:

- **Full-text search** for the classic case — find the rows whose text matches a
  query, ranked by relevance.
- **Vector search** for semantic and similarity work — find the rows closest to
  an embedding, which is what powers recommendations and retrieval for
  AI features.

Because both ride the same query path, you can combine them with the filters,
owner-scoping and aggregates you already use. Search results obey the same
per-request isolation as every other read: a query only ever sees the caller's
own rows.

## Available from the smallest binary up

The no-rewrite promise applies here too. Search behaves the same whether you are
running the 5 MB nano binary on a spare machine or the multi-tenant platform: the
API does not change as you grow. You add search to a prototype and that code
keeps working when the prototype becomes a product.

## Honest about scope

Search is engine-backed, so the exact capabilities follow the engine your data
lives in — that is the trade-off of being engine-agnostic rather than shipping a
single bundled search engine. What stays constant is the API surface and the
isolation guarantees. We measure search behaviour on the real stack like
everything else on this site; if we cannot measure a claim, we do not make it.

Read the [search guide](/docs/guides/) to wire full-text and vector search into
your app, or see how the engines fit together in
[Connectors](/resources/connectors/).
