# Supabase Studio

Supabase Studio — web-based admin dashboard for managing your Supabase project. Provides a GUI for browsing tables, running SQL, managing auth users, storage, and more.

## Quick Start

```bash
docker compose --profile studio up -d studio
```

## Access — never through the gateway

Studio holds the `service_role` key and has no login of its own, so there is
**no Kong route to it** (the old `/studio` route was removed: Studio is built
without a `basePath`, so it only serves at `/` and that route only ever 404'd).
Gate m206 fails if a Kong service points at `studio` again.

- **Dev:** compose publishes it on the loopback only:
  `http://127.0.0.1:${STUDIO_PORT:-3000}`.
- **Production:** the prod overlay removes that port. Tunnel to the container
  from your workstation instead:

  ```bash
  # on the server: the container's bridge IP
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' mini-baas-studio
  # on your workstation: forward local 3000 to it, then open http://127.0.0.1:3000
  ssh -N -L 3000:<that IP>:3000 you@your-server
  ```

Every container on the `mini-baas` bridge can still reach `studio:3000` without
credentials. Keep the `studio` profile off in production unless you need it.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STUDIO_DEFAULT_ORGANIZATION` | `Default Organization` | Organization name shown in the UI |
| `STUDIO_DEFAULT_PROJECT` | `Default Project` | Project name shown in the UI |
| `SUPABASE_URL` | `http://kong:8000` | Internal URL to the Kong API gateway |
| `SUPABASE_PUBLIC_URL` | `http://localhost:8000` | Public-facing URL for API calls from the browser |
| `SUPABASE_ANON_KEY` | — | Anonymous API key for client-side requests |
| `SUPABASE_SERVICE_ROLE_KEY` | — | Service role key for admin operations |
| `STUDIO_PORT` | `3000` | Host port, bound to 127.0.0.1 (dev only; the prod overlay removes it) |

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Studio dashboard UI |
| `GET` | `/project/default` | Default project overview |
| `GET` | `/project/default/editor` | Table editor |
| `GET` | `/project/default/sql` | SQL editor |
| `GET` | `/project/default/auth/users` | Auth user management |
| `GET` | `/project/default/storage` | Storage browser |

## CLI Examples

```bash
# Open Studio in your browser
open http://127.0.0.1:3000

# Or on Linux
xdg-open http://127.0.0.1:3000

# Verify Studio is running
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000
# → 200
```

## Health Check

```bash
curl -sf http://127.0.0.1:3000/
```

Returns `200` with the Studio HTML page when the service is running.

## Docker

- **Image:** `supabase/studio`
- **Internal Port:** `3000`
- **Host Port:** `127.0.0.1:${STUDIO_PORT:-3000}` (dev only)
- **Depends on:** `kong` (API gateway)
- **Networks:** Internal `baas` network
