# Canagrou on Grobase

Canagrou's PHP + MariaDB backend has been replaced by the **Grobase BaaS**. Both
frontends — the web app (`web/`, a zero-build JS SPA) and the Flutter app
(`mobile/`) — now talk directly to Grobase through the Kong gateway. The one
capability Grobase does not provide, **server-side image overlay + GIF
composition**, moved client-side into **`services/`** (the plugin layer for
not-covered capabilities).

## What maps where

| Canagrou feature | Grobase surface | Notes |
|---|---|---|
| register / login / logout / verify / reset | GoTrue `/auth/v1` (JWT) | autoconfirm ON in dev → register logs you straight in; recovery mail → Mailpit |
| users / posts / likes / comments | `/query/v1/<dbId>/tables/<t>` | dedicated `canagrou` Postgres DB; **writes carry the per-user GoTrue JWT** (owner `user:<sub>`, owner-scoped per request); **reads stay anonymous** so the wall is public |
| image files | storage `/storage/v1` | one shared `canagrou-app` identity (public wall); browser blob-fetches |
| overlay + animated GIF | **`services/composition`** (client-side canvas / `package:image`) | replaces GD + `GifEncoder.php` |
| comment-notify email | `services/notifier` (best-effort, no-op without an edge fn) | GoTrue handles verify/reset mail natively |
| live gallery/likes/comments | realtime WS `table:<dbId>:<table>` | writes through `/query` publish the event |

Data model: GoTrue `auth.users` owns identity; an app `profiles` row owns
`username` + `notify_comments`, keyed by the GoTrue user id. Posts store a
storage **object key**, not bytes.

**Authorship is server-bound (anti-impersonation).** Every `/query` write now
sends `Authorization: Bearer <jwt>` when the user is signed in, so the data plane
stamps `owner_id = user:<sub>` from the *verified* identity and owner-scopes the
write — `update`/`delete` of another user's row affect 0 rows by construction. The
social author column (`posts/likes/comments.user_id`, `profiles.id`) is
client-supplied, so a `BEFORE INSERT` trigger (`bind_author_from_owner` /
`bind_profile_id_from_owner`, in `sql/grobase-schema.sql`) overwrites it from
`owner_id` whenever that carries the `user:` prefix: a forged `user_id` is coerced
to the real `sub`. Anonymous app-key writes (owner `api-key:<id>`, no `user:`
prefix) pass through unchanged, so the public wall and the seed path are
unaffected. Storage/realtime keep the single shared `canagrou-app` identity (only
the `/query` write path is per-user). Proven by the `m146` anti-impersonation step.

## Run it

```bash
# from the repo root — the stack must be up (auth+query+storage+realtime planes)
bash scripts/seed/canagrou-tenant.sh        # provision tenant+key+mount+schema+bucket+tokens, emit env (idempotent)

# web SPA — served over HTTPS (self-signed localhost cert auto-generated);
# it talks ONLY to its own origin (same-origin reverse proxy → Kong), so no CORS.
sh vendor/Canagrou/web/serve.sh             # → https://localhost:8123  (NO_TLS=1 for http)

# Flutter (Android emulator host = 10.0.2.2; mobile/.env is generated)
cd vendor/Canagrou/mobile && flutter pub get && flutter run
```

## Test it

```bash
bash vendor/Canagrou/test.sh            # web wiring (offline) + web smoke (live) + browser (Playwright) + m146 gate + flutter
bash vendor/Canagrou/test.sh browser    # the real-browser Playwright suite (HTTPS, fake webcam, 2 contexts)
bash vendor/Canagrou/test.sh gate       # just the live e2e gate
bash scripts/verify/m146-canagrou-roundtrip.sh   # the gate directly
```

`m146` proves the data chain live (signup→JWT, profile, post insert→read-back,
like, comment, storage byte-roundtrip, realtime EVENT to a non-writer, cross-user
read) **and the anti-impersonation gate**: with U1's JWT a forged `user_id` is
read back coerced to U1 (never U2), U1's `delete`/`update` of U2's post affect 0
rows, and U2's post still reads unaltered (public wall intact). The **Playwright** suite (`web/test/browser-full.mjs` + `browser-e2e.mjs`)
drives the actual UI in Chromium over HTTPS: register (+validation), webcam &
upload capture→post, like±, comment, settings, logout, login (wrong+right), and
**realtime reflection across two browser contexts** — all green, clean console.

## Notes / gotchas

- **Connection is HTTPS.** `serve.mjs` is a static server + same-origin reverse
  proxy to Kong (HTTP + WebSocket), so the browser only ever talks to
  `https://localhost:8123` — no CORS, and login/portal traffic is TLS-encrypted.
- **Storage** has no public/anon GET and no browser-reachable signed URL
  (`S3_PUBLIC_ENDPOINT` unset), so every image lives under one shared storage
  identity; the client fetches bytes through the proxy with the storage token and
  renders from memory (web: `objectUrl` blob; Flutter: `Image.memory`).
- **BaaS fix applied:** Kong's `storage-sign` route (which catches the
  `/storage/v1/object` upload path) was capped at 16KB — uploads 413'd. Aligned to
  10MB (the sibling storage route's limit) in `infra/docker/services/kong/conf/kong.yml`.
- **Realtime is posts-only in the gallery** (new photos appear live); likes/comments
  update in-card, so the feed doesn't rebuild and lose in-progress UI.

The old PHP backend (`app/`, `php/`, `nginx/`, `sql/init.sql`, `docker-compose.yml`)
is superseded and can be retired once you're satisfied with the Grobase build.
