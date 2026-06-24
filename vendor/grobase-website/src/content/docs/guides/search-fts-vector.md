---
title: Search — full-text & vector
description: First-class full-text and vector search across your data, queried through the same uniform API as everything else.
section: Guides
order: 6
---

# Search — full-text & vector

Search is first-class in Grobase. Both **full-text** search (keyword relevance)
and **vector** search (semantic similarity) are part of the platform and queried
through the same uniform API as the rest of your data — no separate search service
to operate.

## Full-text search

Match documents by keywords, ranked by relevance:

```
const hits = await db
  .from('articles')
  .search('body', 'engine agnostic backend')
  .limit(10);
```

Results are owner-scoped like any read — you search only what you are entitled to
see.

## Vector search

Find the most semantically similar records to an embedding — the foundation for
recommendations, retrieval and AI features:

```
const similar = await db
  .from('articles')
  .nearest('embedding', queryVector)
  .limit(5);
```

Store the embedding alongside your row and query nearest-neighbour matches with one
call.

## Combine both

Full-text and vector search compose with ordinary filters, so you can constrain a
semantic query to a subset of rows:

```
await db
  .from('articles')
  .eq('lang', 'en')
  .nearest('embedding', queryVector)
  .limit(5);
```

## Why it matters

Because search lives in the same data plane, indexing stays consistent with your
writes and the access rules are identical to your reads. You get keyword and
semantic search without a second system to keep in sync.

## Next steps

Feed search results into server logic with [Functions](/docs/guides/functions/),
or stream new matches as they are written with [Realtime](/docs/guides/realtime/).
