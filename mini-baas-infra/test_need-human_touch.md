All artifacts verified — here's the exact step-by-step runbook for each human atom, grounded in the real repo. For each: 🔵 = needs your
  login/account (web UI, only you can), ⚪ = a command (you run it, or paste it here prefixed with ! and I'll run + debug it). Where it's a
  tag/deploy, once your 🔵 prereqs exist you can just tell me "done" and I'll push it.
     
  ---
  1. npm SDK publish — @mini-baas/js v0.2.0 (most ready)
  
  🔵 a. Create the npm org — npmjs.com → avatar → Add Organization → name mini-baas → Free.
  🔵 b. Create an automation token — npmjs.com → avatar → Access Tokens → Generate → Granular Access Token (or Classic Automation — this is
  the one that bypasses the 2FA OTP that CI can't enter) → read/write on scope @mini-baas → copy (npm_…).
  🔵 c. Add it as the GitHub secret — github.com/Univers42/groot → Settings → Secrets and variables → Actions → New repository secret → name
  NPM_TOKEN, value = the token.
  ⚪ d. Publish (the tag fires .github/workflows/baas-cli-publish.yml → npm publish --provenance --access public):
  cd /home/dlesieur/Documents/ft_transcendence && git tag baas-cli-v0.2.0 && git push origin baas-cli-v0.2.0
  ⚪ e. Verify: npm view @mini-baas/js version
  
  ▎ Skip the new-org step: if you already own an npm org, I can rename the package scope to it (@<yourorg>/baas) and you only do steps b–d. 
  ▎ Tell me the org. After a/b/c exist, you can also just say "npm ready" and I'll push the tag for you.
  
  ---
  2. 100K-tenant load SLO (C6) — needs a quiet node (this box is CPU-starved)
  
  On any idle machine with Docker (data-root on a big disk), after cloning the repo:
  cd <repo>/apps/baas/mini-baas-infra
  docker compose -f docker-compose.yml -f docker-compose.scale.yml up -d
  SCALE=100000 RATE=20 DURATION=60s DIST=zipf PREFIX=scale-100k bash scripts/scale/load-100k.sh
  Seed is resumable (~50 min Argon2id wall). Result → artifacts/scale/load-100k-100000.json. Then:
  git add artifacts/scale/load-100k-100000.json && git commit -m "perf(baas): 100K-tenant load SLO (C6)" && git push origin
  feat/baas-scale-program
  
  ---
  3. RS256 live-auth flip (runbook: apps/baas/wiki/security-residuals-runbook.md §G-RS256)
  
  ⚪ a. Re-confirm the proof (safe, scratch-only, run anywhere incl. ! here):
  bash /home/dlesieur/Documents/ft_transcendence/apps/baas/mini-baas-infra/scripts/verify/m81-rs256-issuer.sh
  The only blocker is the issuer: vendored gotrue v2.188.1 signs HS256 only. The live cutover (runbook steps 2–6): bump
  docker/services/gotrue/Dockerfile to a gotrue/auth image with asymmetric JWT signing (Supabase auth ≥ 2025-07 "JWT signing keys") or front
  it with a JWKS signer → private key via Vault → swap Kong jwt_secrets HS256→RS256 → set JWT_ALG=RS256 +
  JWKS_URL=<issuer>/.well-known/jwks.json on tenant-control → make all && make playground (must stay 200 across /rest /query /data /storage) →
  keep HS256 for one 3600 s TTL for instant rollback.
  
  ▎ I can pre-stage this for you: I'll author the gotrue image bump + the Kong/env diffs flag-gated, re-run m81, and leave you only the live 
  ▎ make all && make playground flip + the go/no-go. Just tell me which gotrue image you want (or "you choose").
  
  ---
  4. Stripe live billing (B3)
  
  🔵 a. Create a Stripe account (stripe.com) and activate it.
  🔵 b. Create Billing → Meters matching the reporter's expectations: event names grobase_query_count and grobase_write_rows (add
  storage/realtime/functions meters if you bill them).
  🔵 c. Developers → API keys → copy the Secret key (sk_test_… to rehearse, sk_live_… for real).
  ⚪ d. Wire it (secrets stay out of git) + promote via the ladder:
  cd /home/dlesieur/Documents/ft_transcendence/apps/baas/mini-baas-infra
  cp config/cloud/flags.env.example config/cloud/flags.prod.env
  # edit flags.prod.env: METERING_ENABLED=1  METERING_INGEST=1  DATA_PLANE_METERING=1  (rehearse first)
  #   then a later rung: BILLING_ENABLED=1
  # put the SECRET (your secrets tool or .env, never committed):
  #   STRIPE_API_KEY=sk_live_xxx
  #   BILLING_METER_QUERY_COUNT=grobase_query_count
  #   BILLING_METER_WRITE_ROWS=grobase_write_rows
  cat config/cloud/flags.prod.env >> .env
  make up EDITION=prod
  Each billable tenant also needs a tenant_billing row mapping it to its Stripe cus_…. Enable metering first, watch tenant_usage fill, then 
  flip BILLING_ENABLED (never jump straight to enforce).
  
  ---
  5. Hosted deploy + domain + TLS (B7.6) — the Helm chart is ready & lint-clean
  
  🔵 a. A managed Kubernetes cluster (GKE/EKS/DO/…) — your cloud account + bill. 🔵 b. A domain from any registrar. 🔵 c. DNS access.
  ⚪ d. Install (once kubectl points at the cluster):
  cd /home/dlesieur/Documents/ft_transcendence/apps/baas/mini-baas-infra
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  helm install grobase deploy/helm/grobase --namespace grobase --create-namespace \
    --set ingress.host=api.<yourdomain> --set ingress.tls.enabled=true
  kubectl -n grobase get ingress,pods    # note the ingress EXTERNAL-IP
  ⚪ e. DNS: create an A record api.<yourdomain> → that ingress IP (cert-manager then issues the TLS cert automatically).
  
  ▎ Fly alternative (you already run Vault on Fly): the BaaS planes have no fly.toml yet — I can author one per plane + Fly-Vault secret 
  ▎ wiring if you'd rather go Fly than k8s. Say the word.
  
  ---
  The fastest path + how to hand off to me
  
  The two highest-value, lowest-effort atoms are #1 npm (3 web clicks + I push the tag) and #3 RS256 (I pre-stage, you run one make flip). The
  rest gate on real money/accounts.
  
  You don't have to run any command alone: paste any ⚪ line here prefixed with ! and I'll execute it in-session and debug the output. And for
  #1/#3 I can pre-stage the code right now so your part shrinks to the web-UI clicks — want me to do that?
  
✻ Baked for 3m 31s

