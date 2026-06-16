# Network controls & Cloudflare front-door — vs Supabase

**Status: WIN (in-stack), with one honest parity note.** Grobase ships, in its own
self-hostable stack, an **OWASP-CRS WAF as the sole public listener**, **per-plane
network segmentation**, and **IP allow-listing** — perimeter controls Supabase does
**not** ship in its OSS/self-host stack (Supabase fronts its *managed cloud* with its
own Cloudflare; its open-source `supabase/supabase` compose has no WAF and one flat
Docker network). On the managed side, both products can sit behind Cloudflare; the
copy-pasteable front-door recipe below makes that path explicit for a Grobase deploy.

Everything in the "what we ship" sections is **measured/proven by a gate** and cited
inline. Cloudflare config snippets are a **deployment recipe (ROADMAP for a hosted
deploy)** — clearly labelled as such, not claimed as a measured in-stack control.

> Gate proving the in-stack controls: `mini-baas-infra/scripts/verify/m140-network-controls.sh`
> (run: `bash mini-baas-infra/scripts/verify/m140-network-controls.sh`). It proves the
> live WAF blocks SQLi/XSS/traversal (403, CRS) and passes benign traffic, and that
> per-plane segmentation refuses an edge→data socket while allowing the legal
> front-door. Segmentation parity/superset is also proven by `m66-netseg.sh`.

---

## 1. In-stack OWASP-CRS WAF — the sole public listener (clear edge)

The **only** container that binds a public port is the WAF: nginx + **ModSecurity v3 +
OWASP Core Rule Set v4** (`owasp/modsecurity-crs:4-nginx-202604040104`). Kong, the API
gateway, is moved *behind* it — `docker-compose.yml` exposes Kong only on
`127.0.0.1` for dev, never on `0.0.0.0`. Every WAN request is inspected by the CRS
before it can reach any application route.

- **Build:** `mini-baas-infra/docker/services/waf/Dockerfile`
  (`FROM owasp/modsecurity-crs:4-nginx-202604040104`).
- **Config:** `docker/services/waf/conf/{nginx,modsecurity,crs-setup}.conf`.
  - `SecRuleEngine On` (blocking, not detect-only) — `modsecurity.conf:8`.
  - Paranoia level 2, inbound anomaly threshold 5, outbound 4 — `crs-setup.conf`.
  - Body inspection on (10 MiB limit, reject on overflow); response-body off.
  - Tuned exclusions so legitimate PostgREST filter syntax (`?col=eq.value`) and
    Bearer tokens are not false-positives — `modsecurity.conf:45-77`.
- **Sole public listener:** `nginx.conf` proxies `location /` → `http://kong:8000`;
  the only WAF-bypass is `GET /waf-health` (a static 200 for liveness).

### What the gate proves, live

Probing the running WAF (`http://127.0.0.1:${WAF_HTTP_PORT}` → host 8881) the gate
records the **real** HTTP status and the **CRS rule IDs** that fired (from the
ModSecurity JSON audit log):

| Probe | Result | CRS rule(s) |
|---|---|---|
| `GET /waf-health` (benign) | **200** | bypass (liveness) |
| `GET /data/v1/health` (benign real route) | **passes WAF** → Kong's 401 (auth), **not 403** | — |
| `?id=1' OR '1'='1 -- UNION SELECT …` (SQLi) | **403** | `942100` (libinjection SQLi) |
| `?q=<script>alert(1)</script>` (XSS) | **403** | `941100/941110/941160/941390` (libinjection + CRS XSS) |
| `?file=../../../../etc/passwd` (traversal) | **403** | `930100/930110/930120` (LFI) + `932160` (RCE) |

**Negative control:** the same SQLi sent **directly to Kong** (bypassing the WAF)
returns 404, **not 403** — proving the 403 originates at the WAF/CRS layer, not at
Kong. The block also exceeds the CRS anomaly threshold (`949110`, score ≥ 5), so it is
the CRS scoring engine doing the work, not an ad-hoc rule.

> Supabase's self-host stack (`supabase/supabase` docker-compose) has **no WAF
> container**. An OSS Supabase operator must add their own (Cloudflare, a cloud WAF,
> or a hand-rolled ModSecurity) — Grobase ships it on by default.

---

## 2. Per-plane network segmentation (`docker-compose.netseg.yml`)

By default the stack runs on one flat `mini-baas` bridge — simple, and **byte-parity**
is the proven baseline. The **additive** overlay `docker-compose.netseg.yml` splits the
stack into four isolated bridges with a default-deny posture; two containers can reach
each other **iff** they share a bridge:

| Bridge | `internal:` | Members | Reach |
|---|---|---|---|
| `net-edge` | no (public) | waf, kong, studio, playground, gotrue, postgrest, realtime, grafana | WAN ingress |
| `net-control` | **true** | tenant-control, orchestrator, permission-engine, schema-service, webhook-dispatcher, function-scheduler, vault | no WAN egress |
| `net-data` | **true** | postgres, mysql, mariadb, cockroach, mssql, mongo, redis, minio | engines — no WAN egress |
| `net-observ` | **true** | prometheus, grafana, loki, promtail | scrape-only dead-end |

The **only legal edge→data path** is a dual/triple-attached front-door:
`query-router` and `data-plane-router-rust` are on `net-edge + net-control + net-data`;
`adapter-registry-go` and `tenant-control` bridge `net-control + net-data`. A
compromised edge container (e.g. a Kong RCE) **cannot** open a raw socket to
`postgres:5432`, `vault:8200`, or `redis:6379` — it has no bridge to them; it must go
through the routers, where owner-scope/RLS ABAC is enforced per request.

- **internal-only data/control:** `net-data` and `net-control` are
  `internal: true`, so the engines and control services have **no host/WAN egress**.
- **Off-is-parity:** Compose can only *merge* (add) an override's `networks:` list, not
  remove the base `mini-baas` entry — so composing the overlay is a **strict superset**
  (nothing that worked stops working). Not composing it ⇒ the live topology is
  byte-identical. Proven by `m66-netseg.sh` (ARM 1).
- **Hard isolation proof:** the segmentation gate stands up the *exact* plane wiring on
  a throwaway scratch with **no escape bridge** and proves the negative edge for real:
  `kong (net-edge) → postgres:5432` is **REFUSED**, while
  `query-router (front-door) → postgres:5432` **CONNECTS**. (`m66-netseg.sh` ARM 2 and
  `m140-network-controls.sh` netseg arm.)

> Supabase's OSS compose runs every service on **one default Docker network** — a
> compromised edge service can reach Postgres directly. Per-plane segmentation is a
> Grobase-only in-stack control.

---

## 3. IP allow-listing / network restrictions

Two complementary controls:

1. **Edge IP allow-listing (Kong `ip-restriction`).** Internal/admin routes
   (`/admin/v1/*`, tenant-control, adapter-registry) are bound to private CIDRs
   `[10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.1]` — see `kong.yml`
   (`ip-restriction` plugin on the admin/internal services). Public data/auth routes
   are reachable; control-plane routes are not exposed to the WAN at all.

2. **Per-tenant IP allowlist (control-plane, opt-in).** A tenant restricts which
   source IPs/CIDRs may call *its* API. The decision is an edge auth-request check:
   Kong calls `POST /v1/ipguard/check {tenant_id, ip}` before forwarding; an
   out-of-range client IP ⇒ `allow=false` ⇒ 403. CIDR containment runs in Go,
   engine-agnostic. A tenant with **no** rule is unrestricted (opt-in). Flag
   `TENANT_IP_ALLOWLIST_ENABLED`, migration `049`, **gate `m106-ip-allowlist.sh`**.
   Management: `GET/POST/DELETE /v1/tenants/{id}/ip-allowlist`.

**vs Supabase "Network Restrictions":** Supabase offers project-level DB network
restrictions (allowed CIDRs to the Postgres port) on paid plans. Grobase's
control-plane per-tenant allowlist is the close analogue and is **enforced at the
application edge for every API call** (not only the DB port), is **self-hostable**, and
**re-verifiable** by the operator via the gate. Honest note: Supabase's restriction is
a managed-platform feature with a polished dashboard; Grobase's is config + a
control-plane endpoint (a dashboard toggle is a DX nicety, not a control gap).

---

## 4. Cloudflare front-door recipe (deployment ROADMAP — hosted/managed deploy)

For a **hosted** Grobase deployment, put Cloudflare in front of the WAF as a second,
defense-in-depth perimeter (the in-stack WAF stays on — belt and braces). The snippets
below are a copy-pasteable recipe; they are **deployment config, not an in-stack
measured control**.

### 4.1 DNS — proxied (orange-cloud)

```
# Terraform — cloudflare_record
resource "cloudflare_record" "api" {
  zone_id = var.zone_id
  name    = "api"                 # api.grobase.example
  type    = "A"
  value   = var.origin_ip         # the host running the in-stack WAF (:443)
  proxied = true                  # ORANGE cloud — traffic flows through Cloudflare
  ttl     = 1                     # 1 = automatic when proxied
}
```

Only the proxied hostname is public; the origin's `:443` should be firewalled to accept
**only Cloudflare IP ranges** (see 4.5 authenticated origin pull for the strong form).

### 4.2 WAF managed rules + custom rules

```
# Terraform — cloudflare_ruleset, phase = http_request_firewall_managed
resource "cloudflare_ruleset" "waf_managed" {
  zone_id = var.zone_id
  name    = "grobase-managed-waf"
  kind    = "zone"
  phase   = "http_request_firewall_managed"
  rules {
    action = "execute"
    action_parameters { id = "efb7b8c949ac4650a09736fc376e9aee" } # Cloudflare Managed Ruleset
    expression = "true"
    enabled    = true
  }
  rules {
    action = "execute"
    action_parameters { id = "4814384a9e5d4991b9815dcfc25d2f1f" } # OWASP Core Ruleset
    expression = "true"
    enabled    = true
  }
}

# Custom rule: block the control-plane paths at the edge (defense in depth — they are
# already not exposed, but block them at Cloudflare too).
resource "cloudflare_ruleset" "waf_custom" {
  zone_id = var.zone_id
  phase   = "http_request_firewall_custom"
  kind    = "zone"
  name    = "grobase-custom"
  rules {
    action     = "block"
    expression = "(http.request.uri.path contains \"/admin/v1/\")"
    enabled    = true
  }
}
```

### 4.3 Rate-limiting rules

```
resource "cloudflare_ruleset" "ratelimit" {
  zone_id = var.zone_id
  phase   = "http_ratelimit"
  kind    = "zone"
  name    = "grobase-ratelimit"
  rules {
    action = "block"
    ratelimit {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = 60
      requests_per_period = 600          # per-IP API budget; tune per tier
      mitigation_timeout  = 600
    }
    expression = "(http.request.uri.path contains \"/data/v1/\")"
    enabled    = true
  }
}
```

This complements the in-stack per-tenant token bucket (gate `m51`) — Cloudflare absorbs
volumetric floods at the edge before they reach the origin WAF.

### 4.4 Bot management / Turnstile

```
# Turnstile (CAPTCHA-less challenge) on auth/signup to stop credential stuffing.
resource "cloudflare_ruleset" "bot_challenge" {
  zone_id = var.zone_id
  phase   = "http_request_firewall_custom"
  kind    = "zone"
  name    = "grobase-bot"
  rules {
    action     = "managed_challenge"
    expression = "(http.request.uri.path contains \"/auth/v1/signup\") or (cf.client.bot_score lt 30)"
    enabled    = true
  }
}
```

Pair with a Turnstile widget on the signup/login form; verify the
`cf-turnstile-response` token server-side before issuing a session.

### 4.5 Full-strict TLS + authenticated origin pull (mTLS to origin)

Set the zone SSL mode to **Full (strict)** so Cloudflare validates the origin
certificate, and enable **Authenticated Origin Pulls (mTLS)** so the origin accepts
**only** Cloudflare:

```
resource "cloudflare_zone_settings_override" "tls" {
  zone_id = var.zone_id
  settings {
    ssl                      = "strict"     # Full (strict): validate origin cert
    min_tls_version          = "1.2"
    tls_1_3                  = "on"
    always_use_https         = "on"
    automatic_https_rewrites = "on"
  }
}

resource "cloudflare_authenticated_origin_pulls" "aop" {
  zone_id = var.zone_id
  enabled = true
}
```

On the origin **WAF nginx** (`docker/services/waf/conf/nginx.conf`), require the
Cloudflare client certificate so a request that did not come through Cloudflare is
rejected with TLS — this turns "firewall to CF IPs" into cryptographic origin lock:

```nginx
# add to the server { } block in nginx.conf, alongside the existing ssl_certificate*
ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem; # CF's AOP CA
ssl_verify_client      on;        # reject any client without a valid CF cert
```

(Download Cloudflare's origin-pull CA and mount it next to the existing
`localhost.pem` / `localhost-key.pem` volumes.)

### 4.6 Cache rules

```
resource "cloudflare_ruleset" "cache" {
  zone_id = var.zone_id
  phase   = "http_request_cache_settings"
  kind    = "zone"
  name    = "grobase-cache"
  # NEVER cache API/auth — they are per-tenant + authenticated.
  rules {
    action = "set_cache_settings"
    action_parameters { cache = false }
    expression = "(http.request.uri.path contains \"/data/v1/\") or (http.request.uri.path contains \"/auth/v1/\")"
    enabled    = true
  }
  # Cache static assets (studio/playground/docs) aggressively.
  rules {
    action = "set_cache_settings"
    action_parameters {
      cache = true
      edge_ttl { mode = "override_origin" default = 86400 }
    }
    expression = "(http.request.uri.path.extension in {\"js\" \"css\" \"png\" \"svg\" \"woff2\"})"
    enabled    = true
  }
}
```

> **Honest framing:** items in §4 are a deployment recipe a Grobase operator applies —
> they are not a measured in-stack control and are labelled ROADMAP. Supabase's managed
> cloud already runs behind Cloudflare; this recipe gives a Grobase hosted deploy the
> same outer perimeter *in addition to* the in-stack WAF Supabase OSS lacks.

---

## 5. vs Supabase — verdict table

| Control | Supabase OSS self-host | Supabase managed cloud | Grobase (in-stack) | Verdict |
|---|---|---|---|---|
| **In-stack WAF (OWASP CRS)** | ✗ none | via their Cloudflare (not in-stack) | ✅ ModSecurity v3 + CRS v4, sole public listener, blocking, gate-proven | **WIN** — we ship it in the box |
| **Per-plane network segmentation** | ✗ single flat network | platform-internal (opaque) | ✅ 4 isolated bridges, edge↛data refused, gate `m66`/`m140` | **WIN** in self-host; even with managed |
| **IP allow-listing / network restrictions** | ✗ (DIY) | ✓ project network restrictions (paid) | ✅ Kong edge IP-restrict (admin) + per-tenant control-plane allowlist (gate `m106`) | **parity** (we enforce on every API call + self-host re-verifiable; they have a nicer dashboard) |
| **Edge rate-limiting / DDoS** | DIY | ✓ Cloudflare-fronted | ~ in-stack per-tenant token bucket (`m51`) + WAF CRS; volumetric DDoS needs the §4 Cloudflare front-door | **parity-with-caveat** (close-path = §4 recipe) |
| **Origin TLS / mTLS lock (AOP)** | DIY | ✓ Cloudflare AOP | ROADMAP via §4.5 (nginx `ssl_verify_client`) | **parity once §4.5 applied** |
| **Self-host data residency for all of the above** | ✓ (but you build the perimeter) | ✗ (their cloud) | ✅ runs entirely in the operator's own infra | **WIN** |

**Honest bottom line.** For a **self-hosted** deployment Grobase decisively wins the
perimeter: it ships an OWASP-CRS WAF as the sole public listener and per-plane
segmentation that Supabase OSS simply does not have. For **edge DDoS scrubbing** and
**managed network restrictions with a dashboard**, Supabase's hosted product leans on
Cloudflare and a polished UI; the §4 recipe closes that by putting the *same*
Cloudflare front-door in front of a Grobase deploy — **on top of** the in-stack WAF, so
a Grobase hosted deploy ends up with two perimeters where Supabase has one.

---

## 6. Reproduce

```bash
# In-stack network controls (WAF block/pass + segmentation edge↛data):
bash mini-baas-infra/scripts/verify/m140-network-controls.sh

# Segmentation parity/superset + hard-isolation (throwaway scratch):
bash mini-baas-infra/scripts/verify/m66-netseg.sh

# Per-tenant IP allowlist enforcement + parity:
bash mini-baas-infra/scripts/verify/m106-ip-allowlist.sh
```

**Artifacts / sources**
- WAF: `mini-baas-infra/docker/services/waf/Dockerfile` + `conf/{nginx,modsecurity,crs-setup}.conf`
- Segmentation: `mini-baas-infra/docker-compose.netseg.yml`
- Edge IP-restrict: `mini-baas-infra/docker/services/kong/conf/kong.yml` (`ip-restriction`)
- Per-tenant allowlist: control-plane `internal/...` + migration `049`, gate `m106`
- Competitive matrix rows 75/76/90 + differentiator D5: `wiki/competitive-matrix.md`
