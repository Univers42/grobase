# Grobase GitHub connect — Vercel relay

The public, secret-light half of the GitHub App connect topology. The App **private key**
and the installation-token minting live in the grobase control plane (fly); this relay
holds **only an HMAC relay secret** and cannot mint a token. Its single job: take GitHub's
install callback and HMAC-sign-and-forward it to fly.

```
42ctl org github connect <org>          # → grobase mints a single-use nonce + install_url (this relay)
  └─ browser → /api/connect-start?nonce  # 302 → github.com/apps/<slug>/installations/new?state=<nonce>
       └─ install App → GitHub redirects → /api/callback?installation_id&state
            └─ relay signs `X-Github-Relay: v1.<ts>.<hmac>` over the body, POSTs to
               {GROBASE_FLY_URL}/v1/github/callback   # fly verifies HMAC, records install, readies nonce
42ctl polls grobase /v1/github/connect/status?nonce   # → linked
```

The signed body is the exact bytes forwarded (`{"installation_id":<n>,"state":"<nonce>"}`);
grobase hashes the raw body, so the relay hashes and sends the identical string. The
signature scheme is grobase's serviceauth v1:
`HMAC-SHA256(secret, "v1\n<ts>\n<hex(sha256(body))>")`, 300 s skew window.

## Routes

| Route | Method | Purpose |
|---|---|---|
| `/` | GET | static info page (`public/index.html`) |
| `/api/connect-start?nonce=…` | GET | 302 → GitHub App install with `state=<nonce>` |
| `/api/callback?installation_id=…&state=…` | GET | sign + forward the install to fly |

## Environment (Vercel project settings)

| Var | Example | Notes |
|---|---|---|
| `GITHUB_APP_SLUG` | `grobase-connect` | the App's URL slug |
| `GROBASE_FLY_URL` | `https://grobase.fly.dev` | the fly control plane base URL |
| `GITHUB_RELAY_SECRET` | (32+ random bytes) | MUST equal grobase's `GITHUB_RELAY_SECRET` |

`GITHUB_RELAY_SECRET` is the only secret here. Never commit it; set it in Vercel project
env and mirror the same value into grobase (`fly secrets set GITHUB_RELAY_SECRET=…`).

## Deploy (HUMAN-ATOM — needs a Vercel account + a registered GitHub App)

```sh
cd deploy/github-relay
npm i
npx vercel deploy --prod            # or connect the repo in the Vercel dashboard
```

Then, in the GitHub App settings, set the **Setup/Install callback URL** to
`https://<your-vercel-app>.vercel.app/api/callback`, and confirm grobase is started with
`GITHUB_CONNECT_ENABLED=1` + matching `GITHUB_RELAY_SECRET`. See the repo `HUMAN-ATOMS.md`
for the full App-registration + `fly secrets` checklist.
