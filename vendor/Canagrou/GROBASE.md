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
| users / posts / likes / comments | `/query/v1/<dbId>/tables/<t>` | dedicated `canagrou` Postgres DB; per-request owner-scoping |
| image files | storage `/storage/v1` | one shared `canagrou-app` identity (public wall); browser blob-fetches |
| overlay + animated GIF | **`services/composition`** (client-side canvas / `package:image`) | replaces GD + `GifEncoder.php` |
| comment-notify email | `services/notifier` (best-effort, no-op without an edge fn) | GoTrue handles verify/reset mail natively |
| live gallery/likes/comments | realtime WS `table:<dbId>:<table>` | writes through `/query` publish the event |

Data model: GoTrue `auth.users` owns identity; an app `profiles` row owns
`username` + `notify_comments`, keyed by the GoTrue user id. Posts store a
storage **object key**, not bytes.

## Run it

```bash
# from the repo root — the stack must be up (auth+query+storage+realtime planes)
bash scripts/seed/canagrou-tenant.sh        # provision tenant+key+mount+schema+bucket+tokens, emit env (idempotent)

# web SPA (zero-build static; calls Kong cross-origin, CORS is open)
PORT=5173 sh vendor/Canagrou/web/serve.sh   # → http://127.0.0.1:5173

# Flutter (Android emulator host = 10.0.2.2; mobile/.env is generated)
cd vendor/Canagrou/mobile && flutter pub get && flutter run
```

## Test it

```bash
bash vendor/Canagrou/test.sh            # web wiring (offline) + web smoke (live) + m146 gate + flutter (offline)
bash vendor/Canagrou/test.sh gate       # just the live e2e gate
bash scripts/verify/m146-canagrou-roundtrip.sh   # the gate directly
```

`m146` proves the whole chain live: signup→JWT, profile, post insert→read-back,
like toggle, comment, storage byte-roundtrip, a realtime EVENT delivered to a
non-writer subscriber, and a second user seeing the first user's post.

## Storage gotcha (why images aren't plain `<img src>`)

This stack has no public bucket / anon object GET and no browser-reachable
signed URL (`S3_PUBLIC_ENDPOINT` unset). So every image lives under one shared
storage identity and the client fetches bytes through Kong with the storage
token, then renders from memory (web: `objectUrl` blob; Flutter: `Image.memory`).

The old PHP backend (`app/`, `php/`, `nginx/`, `sql/init.sql`, `docker-compose.yml`)
is superseded and can be retired once you're satisfied with the Grobase build.
