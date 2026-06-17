---
title: Storage
description: Upload, download and serve files through object storage with the same owner-scoping and capability checks as the database.
section: Guides
order: 4
---

# Storage

Grobase includes object storage for the files your app handles — avatars,
attachments, exports, uploads. It is governed by the same identity and scoping
rules as your data, so a file is as private as the row that points to it.

## Upload a file

```
const { path } = await db.storage.from('avatars').upload('ada.png', file);
```

The upload is recorded against your owner identity. Storage organises files into
**buckets**; create a bucket per kind of asset (`avatars`, `exports`, …).

## Download a file

```
const blob = await db.storage.from('avatars').download('ada.png');
```

You can only read files in scopes you are entitled to — the same per-request check
that guards database reads guards storage reads.

## List and remove

```
const files = await db.storage.from('avatars').list();
await db.storage.from('avatars').remove('ada.png');
```

## Access control

Buckets carry capability rules just like keys do. A read-only key can fetch files
but not write them; owner-scoping keeps each caller's uploads private by default.
Grant wider access deliberately, with policies, only where sharing is intended.

## Next steps

Run logic when a file lands — generate a thumbnail, scan an upload — with
[Functions](/docs/guides/functions/), or index file metadata for
[Search](/docs/guides/search-fts-vector/).
