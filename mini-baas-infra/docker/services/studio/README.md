# Supabase Studio

Supabase Studio — web-based admin dashboard for managing your Supabase project. Provides a GUI for browsing tables, running SQL, managing auth users, storage, and more.

## Quick Start

```bash
docker compose up studio
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STUDIO_DEFAULT_ORGANIZATION` | `Default Organization` | Organization name shown in the UI |
| `STUDIO_DEFAULT_PROJECT` | `Default Project` | Project name shown in the UI |
| `SUPABASE_URL` | `http://kong:8000` | Internal URL to the Kong API gateway |
| `SUPABASE_PUBLIC_URL` | `http://localhost:8000` | Public-facing URL for API calls from the browser |
| `SUPABASE_ANON_KEY` | — | Anonymous API key for client-side requests |
| `SUPABASE_SERVICE_ROLE_KEY` | — | Service role key for admin operations |
| `STUDIO_PORT` | `3000` | Internal port (mapped to host port 8082) |

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
open http://localhost:8082

# Or on Linux
xdg-open http://localhost:8082

# Verify Studio is running
curl -s -o /dev/null -w "%{http_code}" http://localhost:8082
# → 200
```

## Health Check

```bash
curl -sf http://localhost:8082/
```

Returns `200` with the Studio HTML page when the service is running.

## Docker

- **Image:** `supabase/studio`
- **Internal Port:** `3000`
- **Host Port:** `8082`
- **Depends on:** `kong` (API gateway)
- **Networks:** Internal `baas` network
