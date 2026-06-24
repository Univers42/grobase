# MovieVerse — re-platformed onto Grobase

MovieVerse was a **server-rendered Java 17 / Spring Boot + Thymeleaf + MySQL** movie-community app
(auth, reviews, likes, watch-status, lists, reports, a moderation dashboard, roles, audit). Its movie
catalog was a server-side TMDB proxy with a secret key. *(Original project description: [`README.md`](README.md).)*

**The entire backend has been dropped.** MovieVerse now runs as a **static client on
[Grobase](../../README.md)** — the self-hostable, Supabase-wire-compatible BaaS in this repo — with
**no app server of its own**. This is the holistic, step-by-step record of how, plus a reusable
**"connect your app to Grobase like Supabase"** kit so the next person has no pain.

```
vendor/MovieVerse/
├── dist/                 # the NEW app: a static client served by nginx (this is the whole frontend)
│   ├── *.html            # de-Thymeleafed pages (index, login, register, movies, series, movie, serie, profile, dashboard, errors)
│   ├── js/
│   │   ├── config.js          # ← THE ONE FILE YOU EDIT to point at a Grobase instance
│   │   ├── grobase-client.js  # ← THE CONNECTION SEAM (reusable kit); wraps @grobase/js
│   │   ├── layout.js          # shared header/footer + auth nav + search
│   │   ├── main.js            # UI helpers (trailer modal, star widget, read-more)
│   │   └── {index,explorer,movies,series,auth,detail,profile,dashboard,reportModal,carousel}.js
│   ├── css/  img/        # from the original (css paren-repaired — the vendored source had every ");" stripped)
│   └── vendor/sdk/       # the @grobase/js browser ESM build (drop-in for @supabase/supabase-js)
└── grobase/
    ├── tmdb-proxy/       # the catalog proxy (Go) — keeps the TMDB key server-side
    └── nginx.conf        # static serving + original-URL rewrites (/peliculas/{id} → movie.html)
```

## Before → after

| Concern | MovieVerse (dropped) | Grobase (now) |
|---|---|---|
| HTTP / render | Spring MVC + Thymeleaf (server-rendered) | static nginx + ES-module client |
| Auth | Spring Security sessions + bcrypt + CSRF | GoTrue `/auth/v1` (JWT), `mv.auth.*` |
| User data | JPA → MySQL | PostgREST `/rest/v1` + Postgres RLS (migration `066`) |
| Roles / moderation | `users.role` + `@PreAuthorize` | `app_metadata.role` JWT claim + RLS `auth.is_moderator()` |
| Movie catalog | `TmdbService` (secret key in the app) | Go proxy behind Kong `/tmdb/v1` (key stays server-side) |
| "Like count" over private likes | a `count(*)` query | `like_count` SECURITY-DEFINER RPC (migration `067`) |
| Connect seam | (monolith) | `grobase-client.js` = `createClient({url, anonKey})` |

Everything talks **only to Kong** (`/auth/v1`, `/rest/v1`, `/tmdb/v1`). No Java, no MySQL, no Maven.

## The migration, step by step

1. **Data model + RLS** — `scripts/migrations/postgresql/066_movieverse_schema.sql` recreates the 9
   MySQL tables as Postgres tables keyed to `auth.users(id)`, with **Row-Level Security**:
   - reviews are **world-readable**, owner-writable, moderator-or-owner-deletable;
   - likes / watch-status / lists are **strictly owner-scoped** (a user sees only their own rows);
   - reports are reporter-filed, moderator-triaged;
   - a signup trigger provisions a `movieverse_profiles` row (username from sign-up metadata);
   - cross-user **moderation** is unlocked by `auth.is_moderator()`, which reads the MovieVerse role
     from the JWT's `app_metadata.role` claim (set by an admin via the GoTrue admin API).
   `067_movieverse_like_counts.sql` adds `like_count(media_id, media_type)` — a SECURITY-DEFINER RPC
   returning the **global** like total over the owner-scoped `likes` table **without exposing who
   liked what** (the canonical "public aggregate over a private table" pattern).

2. **Catalog proxy (Go)** — `grobase/tmdb-proxy/` is a tiny stdlib-only Go service porting
   `TmdbService` (search / discover / detail, es-ES, genre maps, trailers, providers, cast). It is
   exposed through Kong at **`/tmdb/v1` with key-auth only (no JWT)**, so anonymous visitors browse
   the catalog with just the anon key. The TMDB secret lives in the proxy's env and never reaches the
   browser. *(Why Go, not an edge function: edge functions require a per-user JWT — a public site
   can't satisfy that — and the Deno runtime hung reaching TMDB over IPv6 on the IPv4-only bridge
   network. Go's `net/http` does dual-stack Happy-Eyeballs, reaching TMDB in ~240 ms.)*

3. **Frontend** — every Thymeleaf template became a static HTML shell hydrated by a small ES module;
   every server route became a call through the seam (below). Login is by **email** (GoTrue). The
   original URL structure (`/peliculas/{id}`, `/series/{id}`) is preserved by nginx `try_files`.

4. **Drop the backend** — the Spring app, Maven wrapper, and the MySQL SQL were deleted. `dist/` + the
   Go proxy are the whole app.

5. **Verify** — `scripts/verify/m146-movieverse.sh` proves it live: the catalog is anon-reachable, the
   `like_count` RPC works, and **RLS holds** (one user cannot see another's likes; reviews are public).

---

## The reusable kit — connect *your* app to Grobase (≈3 steps)

Grobase speaks the **Supabase wire protocol**, and `@grobase/js` is a `@supabase/supabase-js` drop-in.
To wire any static frontend:

**1. Point at your instance** — edit `dist/js/config.js`:

```js
window.__GROBASE__ = {
  url: "http://localhost:8002",      // your Kong gateway
  anonKey: "<KONG_PUBLIC_API_KEY>",  // the PUBLIC anon key — safe to ship (RLS enforces access)
  tmdbBase: "/tmdb/v1",
};
```

**2. Use the seam** — `dist/js/grobase-client.js` wraps the SDK and exports one `mv` object. It
absorbs the only two differences from supabase-js: `createClient` takes an **options object**, and
methods **throw** (no `{ data, error }` envelope). Then in any page module:

```js
import { mv } from "./grobase-client.js";

await mv.auth.login({ email, password });            // GoTrue
const reviews = await mv.reviews.list(id, "MOVIE");  // PostgREST + RLS
await mv.likes.toggle(id, "MOVIE", snapshot);        // owner-scoped write
const movies = await mv.tmdb.discover("movie", { sort: "popularity.desc" }); // your proxy
```

**3. That's it.** Auth state, owner-scoping, and the catalog all work — the server enforces access by
RLS, so the public anon key in the browser is safe. `grobase-client.js` + `config.js` are the entire
integration surface; copy them into any project. See also
[`wiki/guides/migrate-from-supabase.md`](../../wiki/guides/migrate-from-supabase.md).

---

## Run it

```bash
# from the grobase repo root
make up                                                   # bring up the BaaS (Kong, GoTrue, PostgREST, Postgres…)
make migrate                                              # applies migrations incl. 066 + 067
docker compose --profile movieverse up -d --build movieverse tmdb-proxy
bash scripts/verify/m146-movieverse.sh                    # prove the data model + catalog live
# open the frontend (dev: http://localhost:5173 by default)
```

- Kong and the frontend run on whatever ports the stack publishes (resolve-ports bumps busy ones —
  `docker port mini-baas-kong 8000/tcp` shows the live Kong port; keep `config.js` `url` and the
  `KONG_CORS_ORIGIN_FRONTEND` origin in sync).
- **Live catalog needs a real TMDB key:** set `TMDB_API_KEY` in the stack `.env` (consumed by the
  `tmdb-proxy` service). Without it the proxy still runs and the site loads — catalog lists just come
  back empty until the key is set. The key never reaches the browser.
