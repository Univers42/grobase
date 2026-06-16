# storage-router

**Internal port**: `3040` · **Container**: `mini-baas-storage-router` · **Profile**: `storage`, `extras`

Object-storage API over MinIO (S3-compatible). Two transfer modes:

- **Proxied** (`/object/*`) — bytes flow through storage-router → MinIO. Works
  with the internal endpoint (`S3_ENDPOINT=http://minio:9000`) with no extra
  config; this is what the SDK `upload()`/`download()` use.
- **Presigned** (`/sign/*`) — returns a signed URL the client uses directly
  against S3 (saves bandwidth). Only reachable by external clients when
  `S3_PUBLIC_ENDPOINT` points at a publicly-routable S3 host.

Every object key is **auto-prefixed with the caller's user id** (`<userId>/<path>`)
for per-user isolation: a user only ever lists/reads/writes/deletes under their
own prefix.

## Endpoints

All routes are mounted at the full public path (`@Controller('storage/v1')`) and
fronted by Kong with `strip_path: false`.

| Method | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes (not under `storage/v1`) |
| `POST` | `/storage/v1/sign/:bucket/*` | Presigned URL; body `{ method:'GET'\|'PUT', expiresIn?, contentType? }` |
| `PUT` | `/storage/v1/object/:bucket/*` | Upload (binary body, proxied) |
| `GET` | `/storage/v1/object/:bucket/*` | Download (proxied) |
| `DELETE` | `/storage/v1/object/:bucket/*` | Delete |
| `GET` | `/storage/v1/list/:bucket?prefix=` | List the caller's objects |
| `GET` | `/storage/v1/bucket` | List buckets |
| `POST` | `/storage/v1/bucket/:name` | Create bucket (idempotent) |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## SDK (`@mini-baas/js`)

Supabase-shaped:

```ts
const bucket = client.storage.from('uploads');
await bucket.upload('avatars/me.png', file, { contentType: 'image/png' });
const blob = await bucket.download('avatars/me.png');
const objects = await bucket.list('avatars/');
await bucket.remove(['avatars/me.png']);
const { signedUrl } = await bucket.createSignedUrl('avatars/me.png', 600, 'GET');

await client.storage.createBucket('uploads');
await client.storage.listBuckets();
// low-level, back-compat:
await client.storage.presign({ bucket: 'uploads', key: 'avatars/me.png', method: 'PUT' });
```

## Auth & isolation

- Kong's global `pre-function` plugin **clears** any client-supplied
  `X-User-*` headers, then sets `X-User-Id` from the verified JWT `sub`.
- storage-router runs in **compat** identity mode (`IDENTITY_HEADER_MODE=compat`)
  and trusts that Kong-set `X-User-Id` on the private network. (It has no
  api-key→signed-identity middleware like query-router; it authenticates
  end-users, not tenant service keys.)
- Isolation today is **owner-prefix only** (`<userId>/…`). Verified: a different
  `sub` cannot list or download another user's objects (404).

> **Honest gap:** fine-grained **ABAC** (`bucket:read`/`bucket:write` via
> permission-engine) is **not yet wired** in the controller/service — only the
> owner prefix enforces isolation. Wiring permission-engine ABAC + per-bucket
> public/private policy + image transforms are the remaining items to reach full
> Supabase-storage parity (tracked under Track A / the competitive matrix).

## Quick check (through Kong)

```bash
# JWT with a sub (HS256, JWT_SECRET, iss=supabase); ANON_KEY for key-auth.
curl -sS -H "apikey: $ANON_KEY" -H "Authorization: Bearer $USER_JWT" \
  -X PUT --data-binary @file.png \
  "http://127.0.0.1:8002/storage/v1/object/uploads/avatars/me.png"
```

## Dependencies

- **MinIO** (internal `:9000`, console `:9001`)
- **Postgres**: `audit_log`

## Key env vars

| Variable | Effect |
|---|---|
| `PORT` | 3040 |
| `S3_ENDPOINT` | MinIO URL (internal `http://minio:9000`) |
| `S3_PUBLIC_ENDPOINT` | Public S3 host for presigned URLs (optional; unset → internal) |
| `S3_ACCESS_KEY` · `S3_SECRET_KEY` | MinIO credentials |
| `S3_REGION` | Default `us-east-1` |
| `PRESIGN_EXPIRES_SECONDS` | Default presign TTL (default 3600) |
| `STORAGE_MAX_UPLOAD_BYTES` | Max proxied upload size (default 50 MiB) |
| `IDENTITY_HEADER_MODE` | `compat` (trust Kong `X-User-Id`) — default for this service |
