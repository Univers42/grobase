# Surfind Spain on Grobase

`vendor/surfind-spain` re-platformed onto the **local Grobase BaaS**. The original
(`vendor/surfind-spain/surfind-spain/`) is a **Laravel 12 / Livewire 4 / MySQL** server-rendered
Spanish surf-beach directory (Fortify auth, spatie roles, Blade views, a Leaflet map). Unlike the
other vendor apps it had **no SPA to repoint** — the UI *was* the PHP backend — so the re-platform
**rebuilds the frontend as a static React SPA** (`web/`) that talks ONLY to the Kong gateway, and the
entire Laravel/MySQL backend is removed. It follows the **MovieVerse/savanna playbook** (app tables in
the shared `public` schema, **role-based RLS via the GoTrue JWT**, owner-scoped user data), not a
data-plane mount.

## What runs where

| Concern | How |
|---|---|
| **Data API** | PostgREST at `/rest/v1/<table>` (Kong → `postgrest:3000`) |
| **Auth** | GoTrue at `/auth/v1` — admin + self-signup visitors |
| **RLS (catalog)** | `locations`/`amenities`/`beach_images`/`amenity_beach` public read; `beaches` public for `status='published'`, admin write |
| **RLS (user data)** | `favorites` owner-scoped (`user_id = surf_uid()`), `comments` public-read-when-published + owner/admin write — via `surf_uid()` (JWT sub) |
| **Roles** | `surf_jwt_role()` reads **`app_metadata`** (server-controlled), never `user_metadata` — no self-signup escalation |
| **Map** | Leaflet (bundled npm pkg, not a CDN — CSP `'self'`) on the detail + `/mapa` pages |
| **Realtime** | `favorites` realtime trigger **dropped** (private); `comments`/`beaches` stay live |
| **Serve** | static `web/dist` behind a same-origin reverse proxy (`grobase/serve.mjs`) → Kong; no CORS |

## Bring it up

```bash
# 1. provision the DB + GoTrue users (idempotent; sources grobase/.env for the ANON_KEY)
bash vendor/surfind-spain/infra/init.sh     # 7 tables + RLS + 16 beaches/24 locations/8 amenities
                                            # + GoTrue admin/visitor + secure-roles + realtime-privacy

# 2. build the SPA (glibc node — host node_modules has the glibc rollup binary)
docker run --rm -v "$PWD/vendor/surfind-spain/web":/app -w /app node:20-bookworm-slim sh -c 'npm install && npm run build'

# 3. serve same-origin (serve.mjs proxies /rest /auth /realtime /storage /query → Kong)
SURFIND_PORT=5183 docker compose --profile surfind up -d surfind
#   …or directly:
#   docker run -d --name mini-baas-surfind --network mini-baas_mini-baas \
#     -v "$PWD/vendor/surfind-spain":/app:ro -w /app/grobase -e PORT=80 -e KONG_URL=http://kong:8000 \
#     -p 5183:80 node:20-alpine node serve.mjs
# → http://localhost:5183   (5180/5181/5182 are gourmand/hypertube/savanna)
```

**Logins:** admin `admin@surfind.es` / `admin1234` (role=admin in app_metadata); demo visitor
`visitor@surfind.es` / `surf-1234`. Visitors also self-register at `/registro`.

## The data model (the removed MySQL backend → Postgres `public`)

7 tables ported from `surfind-spain/database/migrations/*` (`infra/01_schema.sql`), seeded from the PHP
seeders (`infra/02_seed.sql`): **locations** (24 Spanish provinces) · **amenities** (8, with icons) ·
**beaches** (16 real surf spots — name/slug/location/difficulty/description/lat-lng) · **beach_images**
· **amenity_beach** (M:N) · **comments** (reviews, `user_id uuid DEFAULT surf_uid()`) · **favorites**
(`user_id`+`beach_id` PK, owner-scoped). The original `user_id`/`created_by` bigint FKs to a Laravel
`users` table become **uuid = the GoTrue sub** (GoTrue owns users now — no local users table).

## Frontend (the rebuilt SPA, `web/`)

React 18 + Vite + Tailwind + react-router + Leaflet + Zustand, **in Spanish**, cloning the savanna
client. Pages: **Inicio** (`/`), **Playas** (`/playas`, filter by región + dificultad), **beach detail**
(`/playas/:slug` — descripción, amenities, mini-mapa, comentarios, botón Guardar), **Mapa** (`/mapa` —
Leaflet, all 16 beaches as markers), **Comunidad** (`/comunidad` — recent comments), **Mis favoritos**
(`/mis-favoritos`, owner-scoped), **auth** (`/acceder`, `/registro`). The Grobase client
(`src/baas/client.js`) is a PostgREST query-builder + GoTrue auth; owner-scoped calls send the visitor
Bearer (so the data plane stamps `user_id`).

## Deep expansion — a surf-tracking platform (every Grobase plane)

Beyond the directory, surfind is a living surf platform that exercises the whole BaaS
(gate `m161-surfind-deep.sh`):

| Feature | Data / tracking | Plane(s) |
|---|---|---|
| **Beach intel + media** | 30 spots with break_type, swell direction, best tide/season, bottom, wave-quality, crowd, water-temp, hazards + a **procedural ocean SVG cover & gallery** per beach (`web/public/media/beaches/`, served same-origin) + a "ver vídeos" card (real YouTube search, beach cover as poster) | PostgREST + static media |
| **Guías / Blog** | **34 articles** — a written guide per beach (`guia-<slug>`) + general pieces (etiqueta, leer el parte, neoprenos…), markdown-rendered | PostgREST (`articles`) |
| **Mi Bitácora** | private **surf-session log** (spot, date, duration, waves, board, conditions, rating, notes) + a **stats dashboard** (sesiones, olas, horas, spots, racha) | **MongoDB** mount (`surfind-mongo` → `surf_sessions`), owner-scoped per GoTrue user |
| **Reportes en vivo** | post **current conditions** at a spot; the feed prepends new reports **in realtime**; time-series history | PostgREST (`surf_reports`) + **Realtime WS** |
| **Ratings** | star-rate a spot → a **SECURITY DEFINER trigger** recomputes `beaches.rating_avg`/`rating_count` | PostgREST + trigger aggregation |
| **Perfil + Ranking** | public `surfer_profiles` (nivel, quiver, home break, bio) + a leaderboard | PostgREST |

Provision: `infra/{02b_more_beaches,03_deep_schema,04_deep_seed}.sql` (applied by `init.sh`),
`web/scripts/gen-media.mjs` (90 SVGs), and `scripts/seed/surfind-tenant.sh` (the Mongo mount + a demo
bitácora). Realtime: `surf_reports` broadcasts live (public feed); `favorites`/`beach_ratings` triggers
dropped (private). The Mongo session journal is owner-scoped per user exactly like savanna's Visit Journal
(query-router `/query/v1/<dbId>/tables/surf_sessions`, read op `list`, sort `{field:'desc'}`).

## Security

`scripts/verify/m160-surfind-spain.sh` proves, live: (A) data seeded; (B) public catalog readable by
anon while `favorites` are private (0); (C) two visitors A/B isolated — A's favorites/comments invisible
to B, B cannot delete A's comment, admin can; (D) **escalation closed** — a self-signup visitor forging
`user_metadata.role=admin` is rejected (403) on a beach write, because the role is trusted only from
`app_metadata`. Surfind also inherits the platform hardening (Kong admin port closed, adapter-registry
ACL, storage scoping, mailpit — gates m156–m159).

## Gotchas

- **No host SPA to reuse** — the UI was server-rendered Blade/Livewire, so the SPA is a faithful rebuild,
  not a repoint. The original Laravel app stays at `surfind-spain/surfind-spain/` as the "before".
- **`init.sh` reads `grobase/.env` by grep, not `source`** — grobase/.env isn't cleanly shell-sourceable
  (a value runs as a command). The grobase root is **3** levels up from `infra/`, not 4.
- **bigserial inserts need a sequence grant** — `comments` (bigserial id) failed for `authenticated`
  with `permission denied for sequence comments_id_seq` until `GRANT USAGE ON ALL SEQUENCES … TO anon,
  authenticated` was added (`favorites` has no serial, so it never hit this).
- **Build with a glibc node image** (`node:20-bookworm-slim`), not alpine — rollup's native binary.
- **Leaflet is bundled** (npm `leaflet`), not a CDN, to satisfy CSP `connect-src 'self'`.

Verified live (Playwright, :5183, **0 console errors**): Inicio → 16 playas → detalle (mapa Leaflet +
comentarios) → registro → Guardar (favorito) → Mis favoritos → comentario (persiste tras recargar) →
Mapa (16 marcadores) → cerrar sesión. Gate `m160` green + shellcheck clean.
