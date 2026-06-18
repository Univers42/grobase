# GoTrue — Auth Service

Supabase GoTrue authentication service. Provides user signup, login (email/password, OAuth), JWT issuance, token refresh, and user management.

## Quick Start

```bash
docker compose up gotrue
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GOTRUE_JWT_SECRET` | — | Shared JWT secret for signing tokens |
| `GOTRUE_JWT_EXP` | `3600` | Token expiration in seconds |
| `GOTRUE_DB_DATABASE_URL` | — | PostgreSQL connection string (`postgres://...`) |
| `GOTRUE_DB_DRIVER` | `postgres` | Database driver |
| `API_EXTERNAL_URL` | `http://localhost:8000` | Public-facing API URL (Kong proxy) |
| `GOTRUE_SITE_URL` | `http://localhost:3000` | Frontend app URL for redirects |
| `GOTRUE_URI_ALLOW_LIST` | — | Comma-separated allowed redirect URIs |
| `GOTRUE_DISABLE_SIGNUP` | `false` | Disable new user registration |
| `GOTRUE_EXTERNAL_EMAIL_ENABLED` | `true` | Enable email/password auth |
| `GOTRUE_MAILER_AUTOCONFIRM` | `true` | Auto-confirm email signups |

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/signup` | Register a new user |
| `POST` | `/token?grant_type=password` | Login with email + password |
| `POST` | `/token?grant_type=refresh_token` | Refresh an access token |
| `GET` | `/user` | Get current authenticated user |
| `PUT` | `/user` | Update current user |
| `POST` | `/logout` | Revoke the current session |
| `POST` | `/recover` | Send password recovery email |
| `GET` | `/health` | Service health check |

## CLI Examples

```bash
# Sign up a new user
curl -s -X POST http://localhost:9999/signup \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user@example.com",
    "password": "password123"
  }' | jq .

# Login and obtain a JWT
curl -s -X POST 'http://localhost:9999/token?grant_type=password' \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user@example.com",
    "password": "password123"
  }' | jq .

# Retrieve current user (use access_token from login response)
curl -s http://localhost:9999/user \
  -H "Authorization: Bearer <access_token>" | jq .

# Refresh a token
curl -s -X POST 'http://localhost:9999/token?grant_type=refresh_token' \
  -H "Content-Type: application/json" \
  -d '{"refresh_token": "<refresh_token>"}' | jq .

# Logout
curl -s -X POST http://localhost:9999/logout \
  -H "Authorization: Bearer <access_token>"
```

## Health Check

```bash
curl -sf http://localhost:9999/health
```

Returns `200 OK` with `{"status":"ok"}` when the service is healthy.

## Docker

- **Image:** `supabase/gotrue:v2.158.1`
- **Port:** `9999`
- **Depends on:** `postgres` (database for auth tables)
- **Networks:** Internal `baas` network
