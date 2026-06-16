// Package main boots the tenant-control service.
//
// Owns:
//
//	POST /v1/tenants              create a tenant row
//	GET  /v1/tenants              list tenants (admin)
//	GET  /v1/tenants/:id          fetch (self or admin)
//	PATCH/DELETE /v1/tenants/:id  admin
//	POST /v1/tenants/:id/bootstrap   tenant + default role + first key
//	POST /v1/tenants/:id/keys     issue API key
//	GET  /v1/tenants/:id/keys     list keys (redacted)
//	DELETE /v1/tenants/:id/keys/:keyId   revoke
//	POST /v1/keys/verify          gateway-internal: cleartext key -> identity
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/abuseguard"
	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
	"github.com/dlesieur/mini-baas/control-plane/internal/backup"
	"github.com/dlesieur/mini-baas/control-plane/internal/branching"
	"github.com/dlesieur/mini-baas/control-plane/internal/compliance"
	"github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/erase"
	"github.com/dlesieur/mini-baas/control-plane/internal/export"
	"github.com/dlesieur/mini-baas/control-plane/internal/ipguard"
	"github.com/dlesieur/mini-baas/control-plane/internal/metering"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/passkeys"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/push"
	"github.com/dlesieur/mini-baas/control-plane/internal/scim"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/sso"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
	"github.com/dlesieur/mini-baas/control-plane/internal/trust"
)

func main() {
	log := shared.NewLogger("tenant-control")

	cfg, err := shared.LoadConfig("TENANT_CONTROL")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}

	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	db, err := shared.NewPostgres(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	svc := tenants.NewService(db, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		log.Error("schema check failed", "err", err)
		os.Exit(1)
	}

	// Optional adapter-registry client — enables POST /v1/provision to register
	// a tenant's data mounts as part of one declarative reconcile call.
	if arURL := os.Getenv("ADAPTER_REGISTRY_URL"); arURL != "" {
		svc.SetAdapterRegistry(tenants.NewAdapterRegistry(arURL, cfg.ServiceToken))
		log.Info("adapter-registry client enabled", "url", arURL)
	} else {
		log.Warn("ADAPTER_REGISTRY_URL not set — /v1/provision will not register mounts")
	}

	// Optional Rust data-plane client — lets /v1/provision create the per-tenant
	// schema for schema_per_tenant mounts (via /v1/admin/migrate).
	if dpURL := os.Getenv("RUST_DATA_PLANE_URL"); dpURL != "" {
		svc.SetDataPlane(tenants.NewDataPlane(dpURL, cfg.ServiceToken))
		log.Info("data-plane client enabled", "url", dpURL)
	}

	// PermissionEngine seam: direct-SQL ABAC against the same Postgres, with an
	// optional HTTP /permissions/decide self-verify hook (PERMISSION_ENGINE_URL).
	// One role implementation, shared by Bootstrap's seedDefaultRole AND the
	// declarative reconciler below.
	permURL := os.Getenv("PERMISSION_ENGINE_URL")
	perm := provision.NewSQLBackend(db, permURL, cfg.ServiceToken)
	svc.SetPermissionEngine(perm)
	if permURL != "" {
		log.Info("permission-engine self-verify enabled", "url", permURL)
	} else {
		log.Warn("PERMISSION_ENGINE_URL not set — provision Decide() self-verify disabled (role/policy seeding still works via SQL)")
	}

	// Provisioning brain: the declarative reconciler wiring the tenant service,
	// the ABAC seam, and the (optional) mount + schema clients. Route ownership
	// stays in tenants.Mount; this is just the engine it delegates to.
	reconciler := svc.BuildReconciler(perm, log)

	// Optional GoTrue JWT verifier — enables POST /v1/tenants/me/bootstrap.
	// If neither env var is set, that endpoint returns 501.
	jwtSecret := envFirst("GOTRUE_JWT_SECRET", "JWT_SECRET")
	var jwtVerifier *tenants.JWTVerifier
	if jwtSecret != "" {
		v, err := tenants.NewJWTVerifier(jwtSecret, os.Getenv("GOTRUE_JWT_ISSUER"))
		if err != nil {
			log.Error("jwt verifier init failed", "err", err)
			os.Exit(1)
		}
		jwtVerifier = v
		log.Info("jwt verifier enabled", "issuer", os.Getenv("GOTRUE_JWT_ISSUER"))
	} else {
		log.Warn("no GOTRUE_JWT_SECRET/JWT_SECRET set — /v1/tenants/me/bootstrap disabled")
	}

	mux := shared.NewRouter("tenant-control", db)
	tenants.Mount(mux, svc, cfg.ServiceToken, jwtVerifier, reconciler)

	// Metering read-back API (Track-B B1c): GET /v1/tenants/{id}/usage. Purely
	// additive read over public.tenant_usage (migration 040), same admin/self
	// auth + tenant-scoping as GET /v1/tenants/{id}. No flag gates the READ path
	// — when metering is OFF the table is empty and it returns empty aggregates,
	// so this route changes no existing path (that IS the parity story).
	metering.Mount(mux, db, cfg.ServiceToken)

	// Tenant self-service API (Track-B B4a): /v1/tenants/me* — a caller
	// authenticated AS a tenant (API key OR GoTrue JWT) manages its OWN tenant
	// (read tenant+entitlements, read usage, list/issue/revoke keys, change plan).
	// There is no path id, so cross-tenant access is impossible by construction.
	//
	// FLAG-GATED OFF = PARITY: the /me routes are mounted ONLY when
	// TENANT_SELFSERVE_ENABLED is truthy. When OFF (the default) MountSelfServe is
	// never called, so those routes do not exist and a request 404s — byte-
	// identical to today. A malformed manifest fails fast (tiering is a security
	// boundary) but only along this opt-in path; the baseline is untouched.
	if envBool("TENANT_SELFSERVE_ENABLED") {
		manifest, err := packages.Load()
		if err != nil {
			log.Error("tenant self-serve: package manifest load failed", "err", err)
			os.Exit(1)
		}
		tenants.MountSelfServe(mux, svc, jwtVerifier, manifest, envBool("BILLING_ENABLED"))
		log.Info("tenant self-service API enabled (/v1/tenants/me*)", "billing", envBool("BILLING_ENABLED"))

		// ─── Dynamic builder (BUILDER) — per-tenant + operator customization ──────
		// A tenant COMPOSES its own backend (N mounts of any allowed engine, a
		// narrowed custom entitlement, a preview) WITHIN a CEILING; an operator mints
		// a custom entitlement + raises a per-tenant ceiling (a sales deal) without a
		// rebuild. The whole feature is a control-plane RESOLVER SWAP: the EFFECTIVE
		// package (named tier overlaid by the custom entitlement, CLAMPED to the
		// ceiling) is what the adapter-registry stamps as capability_overrides and the
		// quota guard enforces — so the stamp, the engine allowlist, max_mounts, and
		// the rate limiter all work UNCHANGED. ZERO Rust changes. Migration 062 backs
		// public.tenant_entitlements.
		//
		// THE CEILING IS A PRIVILEGE BOUNDARY, enforced at TWO points: ValidateWithin
		// at COMPOSE time (PATCH /me/entitlements → 403 entitlement_exceeds_ceiling)
		// and Clamp at RESOLVE time (the BACKSTOP — a stale over-ceiling row is clamped
		// DOWN on EVERY resolve, never trusted). The self-serve surface has no path id
		// (tenant from credential → no cross-tenant); mount DELETE is caller-scoped
		// (AND tenant_id=$caller — a mount UUID is never a bearer capability). The
		// operator routes ({id}, service-token) are the ceiling authority and bypass
		// the self-serve clamp on WRITE — the resolve-time Clamp still bounds the READ.
		//
		// FLAG-GATED OFF = PARITY: MountBuilder is called ONLY when BUILDER_ENABLED is
		// truthy (AND inside the TENANT_SELFSERVE_ENABLED block — the builder reuses
		// selfAuth). When OFF the routes do not exist (404), the tenant_entitlements
		// table is empty/unread, and resolution is manifest.For verbatim — byte-
		// identical to today, the same discipline as the blocks above. The
		// adapter-registry client (set above when ADAPTER_REGISTRY_URL is present) is
		// REUSED for caller-scoped mount CRUD; a nil client makes only the mount routes
		// 503 (the entitlement routes still work).
		if envBool("BUILDER_ENABLED") {
			builderStore := entitlements.NewStore(db)
			tenants.MountBuilder(mux, svc, jwtVerifier, builderStore, manifest, svc.AdapterClient(), cfg.ServiceToken)
			log.Info("dynamic builder enabled (/v1/tenants/me/{mounts,entitlements,builder} + operator /v1/tenants/{id}/{ceiling,entitlement}) — BUILDER_ENABLED",
				"adapter", svc.AdapterClient() != nil)
		} else {
			log.Info("dynamic builder disabled (BUILDER_ENABLED off) — builder routes not mounted; resolution is the named tier verbatim (byte-parity)")
		}
		// ─── end dynamic builder ──────────────────────────────────────────────────
	} else {
		log.Info("tenant self-service API disabled (TENANT_SELFSERVE_ENABLED off) — /v1/tenants/me* not mounted")
	}

	// Per-tenant backup/restore API (Track-B B6): admin POST/GET
	// /v1/tenants/{id}/backup|backups + POST /v1/tenants/{id}/restore/{backupId},
	// plus an OPTIONAL read-only self-serve GET /v1/tenants/me/backups.
	//
	// FLAG-GATED OFF = PARITY: backup.Mount is called ONLY when
	// TENANT_BACKUP_ENABLED is truthy. When OFF (the default) Mount is never
	// called, so none of the routes are registered and a request 404s — byte-
	// identical to today, the same discipline as TENANT_SELFSERVE_ENABLED above.
	// The artifact store init fails fast (a misconfigured store is a data-safety
	// boundary) but only along this opt-in path; the baseline is untouched.
	//
	// The self-serve READ route is narrowed by a SECOND flag,
	// TENANT_BACKUP_SELFSERVE_ENABLED (also default OFF), exactly as
	// BILLING_ENABLED narrows the tenant self-service surface.
	if envBool("TENANT_BACKUP_ENABLED") {
		store, err := backup.NewStoreFromEnv()
		if err != nil {
			log.Error("backup: artifact store init failed", "err", err)
			os.Exit(1)
		}
		bsvc := backup.NewService(db, store, log)
		// NOTE: the db_per_tenant DSN resolver (bsvc.WithResolver) is intentionally
		// NOT wired yet — the B6 MVP supports schema_per_tenant only (guardIsolation
		// rejects db_per_tenant as deferred, 400). B6b wires the adapter-registry
		// resolver here, re-enables db_per_tenant in guardIsolation + the 042 CHECK,
		// and adds a db_per_tenant round-trip arm to m87.
		backup.Mount(mux, bsvc, cfg.ServiceToken)
		if envBool("TENANT_BACKUP_SELFSERVE_ENABLED") {
			// The tenants Service is the credential resolver (its exported VerifyKey
			// maps an API key -> owning tenant). JWT-bearer backup listing is a B6b
			// deferral (tenants' user->tenant resolver is unexported); an API-key
			// self-serve call covers the primary programmatic case.
			backup.MountSelfServe(mux, bsvc, svc)
			log.Info("tenant backup self-serve read enabled (/v1/tenants/me/backups, API-key)")
		}
		log.Info("per-tenant backup/restore API enabled (/v1/tenants/{id}/backup|backups|restore)")
	} else {
		log.Info("per-tenant backup/restore API disabled (TENANT_BACKUP_ENABLED off) — routes not mounted")
	}

	// Abuse / free-tier KYC-lite guard (Track-B B7.9): internal service-token
	// routes the control plane consults before a sensitive action —
	//   POST /v1/abuse/admit · POST /v1/abuse/suspend|unsuspend · GET /v1/abuse/state/{tenantId}
	// — plus a Redis `tenant:suspended` set the data plane reads cheaply (the same
	// snapshot pattern as B2 quota:over / B7.8 spend:over).
	//
	// FLAG-GATED OFF = PARITY: abuseguard.Mount is called ONLY when
	// ABUSE_GUARD_ENABLED is truthy. When OFF (the default) Init/Mount are no-ops
	// (no Redis connect, no routes, no principal_events row ever written), so a
	// request to any /v1/abuse/* route 404s — byte-identical to today, the same
	// discipline as TENANT_SELFSERVE_ENABLED / TENANT_BACKUP_ENABLED above. Init's
	// Redis failure is non-fatal (admission still enforced off the DB), so an
	// enabled guard never wedges boot on a transient Redis blip.
	ag := abuseguard.NewGuard(log, db, cfg.ServiceToken)
	if ag.Enabled() {
		if err := ag.Init(ctx); err != nil {
			log.Error("abuse guard init failed", "err", err)
			os.Exit(1)
		}
		abuseguard.Mount(mux, ag)
		log.Info("abuse guard enabled (/v1/abuse/admit|suspend|unsuspend|state)")
	} else {
		log.Info("abuse guard disabled (ABUSE_GUARD_ENABLED off) — /v1/abuse/* not mounted")
	}

	// ─── Track-D D3: tenant-facing TAMPER-EVIDENT audit logs ──────────────────
	// A hash-chained, engine-agnostic audit trail (migration 047) + a tenant-
	// facing query/export/verify API. Each event seals a per-tenant chain link
	// hash = sha256(prev_hash || canonical(row)); a tamper (edited payload,
	// deleted/reordered row) breaks the chain at exactly that link, which the
	// verify route reports. The chain is computed IN GO over the stored rows, so
	// it is independent of the data engine.
	//
	// FLAG-GATED OFF = PARITY: audit.Mount is called ONLY when
	// TENANT_AUDIT_ENABLED is truthy. When OFF (the default) Mount is never
	// called, so none of the /v1/audit* routes are registered and a request 404s,
	// and no audit row is ever written — byte-identical to today, the same
	// discipline as TENANT_SELFSERVE_ENABLED / TENANT_BACKUP_ENABLED /
	// ABUSE_GUARD_ENABLED above. The {id} in every route is re-bound in the SQL
	// WHERE, so a tenant can never read or verify another tenant's chain.
	if envBool("TENANT_AUDIT_ENABLED") {
		audit.Mount(mux, audit.NewService(db), cfg.ServiceToken)
		log.Info("tenant audit log enabled (/v1/audit/tenants/{id}/events|export|verify)")
	} else {
		log.Info("tenant audit log disabled (TENANT_AUDIT_ENABLED off) — /v1/audit* not mounted")
	}
	// ─── end D3 ───────────────────────────────────────────────────────────────

	// ─── Track-D D4.4: HARD-ERASE / tenant teardown ────────────────────────────
	// PROVABLE destruction of a tenant's data (today a teardown is SOFT-DELETE
	// only — DELETE /v1/tenants/{id} flips status='deleted' and the rows stay).
	// HARD-erase DROPs the per-tenant schema CASCADE (schema_per_tenant) or DELETEs
	// the tenant's rows from the shared tables (shared_rls), revokes+deletes the
	// tenant's API keys, then writes a TAMPER-EVIDENT D3 audit receipt
	// (audit.Append onto the per-tenant hash chain — proof the erase happened that
	// survives the data going away) AND an erasure_receipts row (migration 048).
	//
	// FLAG-GATED OFF = PARITY: erase.Mount is called ONLY when HARD_ERASE_ENABLED
	// is truthy. When OFF (the default) Mount is never called, so POST
	// /v1/tenants/{id}/erase is not registered and a request 404s — byte-identical
	// to today's soft-delete-only baseline, the same discipline as the audit /
	// backup blocks above. The erase service REUSES the D3 audit service (the
	// receipt is sealed on the same chain D3 exposes), so the proof is verifiable
	// through the existing /v1/audit/tenants/{id}/verify route.
	if envBool("HARD_ERASE_ENABLED") {
		erSvc := erase.NewService(db, audit.NewService(db), log)
		// After an erase deletes the tenant's API keys, flush the verify fast-path
		// cache so the credential dies immediately (not at the cache TTL).
		erSvc.SetKeyCacheFlusher(svc.FlushVerifyCache)
		erase.Mount(mux, erSvc, cfg.ServiceToken)
		log.Info("hard-erase enabled (POST /v1/tenants/{id}/erase) — HARD_ERASE_ENABLED")
	} else {
		log.Info("hard-erase disabled (HARD_ERASE_ENABLED off) — /v1/tenants/{id}/erase not mounted; teardown is soft-delete only")
	}
	// ─── end D4.4 ───────────────────────────────────────────────────────────────

	// ─── Track-D D1: ORGANIZATIONS / TEAMS / MEMBERS / INVITES / RBAC ──────────
	// The keystone control-plane layer BETWEEN a human and a project(=tenant).
	// Orgs sit ABOVE tenants; an org's RBAC matrix gates CONTROL-PLANE actions
	// (provision a project, invite a member, change plan), and org-scoped project
	// creation DELEGATES to the EXISTING reconciler verbatim (a capability gate
	// before, an org_id stamp after — the reconcile itself is byte-identical to
	// /v1/provision). Migrations 043 (orgs/org_members/org_invites + nullable
	// tenants.org_id) + 044 (per-org billing rollup) back it.
	//
	// THE LOAD-BEARING CONSTRAINT (D-026): org-scoping lives ENTIRELY here in the
	// control plane. It NEVER enters RequestIdentity, the RLS GUCs, or the data
	// plane in any way — so per-request isolation + SHARE_POOLS stay byte-
	// untouched. The org RBAC gate is a control-plane decision; it never consults
	// or modifies the data-plane ABAC PDP.
	//
	// FLAG-GATED OFF = PARITY: orgs.Mount is called ONLY when ORG_MODEL_ENABLED is
	// truthy. When OFF (the default) Mount is never called, so none of the
	// /v1/orgs* routes are registered (404) and no orgs/org_members/org_invites
	// row is ever written — byte-identical to today, the same discipline as
	// TENANT_SELFSERVE_ENABLED / TENANT_BACKUP_ENABLED / ABUSE_GUARD_ENABLED /
	// TENANT_AUDIT_ENABLED above. The org handlers REUSE the existing reconciler +
	// tenant service + jwtVerifier — no new data path, just a new authorization
	// gate above the existing provision call. A nil jwtVerifier (no
	// GOTRUE_JWT_SECRET) leaves the org routes mounted but every call 501s, since
	// an org decision is always a human (JWT) decision.
	if envBool("ORG_MODEL_ENABLED") {
		osvc := orgs.NewService(db, log)
		// Pass the org JWT seam ONLY when a verifier is configured. A typed-nil
		// *tenants.JWTVerifier boxed into the interface is non-nil (the classic Go
		// nil-interface trap), which would make authJWT call Verify on a nil
		// pointer; passing an untyped nil keeps the rt.jwt == nil guard honest.
		if jwtVerifier != nil {
			orgs.Mount(mux, osvc, svc, reconciler, jwtVerifier, cfg.ServiceToken)
		} else {
			orgs.Mount(mux, osvc, svc, reconciler, nil, cfg.ServiceToken)
		}
		log.Info("organizations API enabled (/v1/orgs*) — ORG_MODEL_ENABLED", "jwt", jwtVerifier != nil)
	} else {
		log.Info("organizations API disabled (ORG_MODEL_ENABLED off) — /v1/orgs* not mounted")
	}
	// ─── end D1 ───────────────────────────────────────────────────────────────

	// ─── Track-D D2e: TENANT-CONFIGURABLE IP ALLOWLIST on the API edge ─────────
	// A tenant restricts which source IPs/CIDRs may call its API. The decision is
	// an EDGE check: an edge auth-request plugin (Kong) calls POST /v1/ipguard/check
	// {tenant_id, ip} before forwarding a request; a tenant with NO allowlist rule
	// is UNRESTRICTED (allow → opt-in), a tenant WITH ≥1 rule is restricted to the
	// union of its CIDRs (an out-of-range IP → allow=false → the edge returns 403).
	// The CIDR containment match runs IN GO (engine-agnostic), and the CRUD lives
	// in the control plane (admin /v1/tenants/{id}/ip-allowlist + self-serve
	// /v1/tenants/me/ip-allowlist). Migration 049 backs it.
	//
	// THE LOAD-BEARING CONSTRAINT (same as D1): enforcement lives ENTIRELY here in
	// the control plane (an edge decision). It NEVER enters RequestIdentity, the
	// RLS GUCs, or the data plane — so per-request isolation + SHARE_POOLS stay
	// byte-untouched.
	//
	// FLAG-GATED OFF = PARITY: ipguard.Mount is called ONLY when
	// TENANT_IP_ALLOWLIST_ENABLED is truthy. When OFF (the default) Mount is never
	// called, none of the /v1/ipguard* or /v1/tenants/{id|me}/ip-allowlist routes
	// are registered (404), and no allowlist is ever consulted — byte-identical to
	// today, the same discipline as TENANT_SELFSERVE_ENABLED / TENANT_AUDIT_ENABLED
	// / HARD_ERASE_ENABLED above. The self-serve CRUD is mounted only when ALSO
	// TENANT_SELFSERVE_ENABLED (the tenants Service is the key→tenant resolver),
	// exactly as backup narrows its self-serve surface.
	if envBool("TENANT_IP_ALLOWLIST_ENABLED") {
		ipsvc := ipguard.NewService(db)
		ipguard.Mount(mux, ipsvc, cfg.ServiceToken)
		if envBool("TENANT_SELFSERVE_ENABLED") {
			ipguard.MountSelfServe(mux, ipsvc, svc)
			log.Info("ip-allowlist self-serve enabled (/v1/tenants/me/ip-allowlist, API-key)")
		}
		log.Info("tenant IP allowlist enabled (POST /v1/ipguard/check + /v1/tenants/{id}/ip-allowlist) — TENANT_IP_ALLOWLIST_ENABLED")
	} else {
		log.Info("tenant IP allowlist disabled (TENANT_IP_ALLOWLIST_ENABLED off) — /v1/ipguard* + ip-allowlist routes not mounted")
	}
	// ─── end D2e ────────────────────────────────────────────────────────────────

	// ─── Track-D D4.1: SOC2-LITE COMPLIANCE EVIDENCE COLLECTOR ─────────────────
	// Snapshots compliance evidence — the CI/gate posture (which mNN gates + CI
	// jobs exist/passed), a platform ACCESS REVIEW (role grants on the control
	// tables), and a git CHANGE-MANAGEMENT trail (recent commits + authors) — into
	// the durable, HASH-SEALED public.compliance_evidence (migration 051). Each of
	// the three section rows is sealed hash = sha256(canonical(section,
	// collected_at, payload)), computed IN GO; a tamper (edited payload/section)
	// breaks that row's seal, which the verify route reports. The collector reads
	// REALITY (a failing/missing control is recorded as failing, never green), and
	// a read API returns the sealed evidence + its verify summary.
	//
	// PLATFORM-LEVEL, ADMIN-ONLY: this evidence is about the platform, not a
	// tenant — every route requires a control-plane SERVICE TOKEN (no tenant-self
	// path), and the 051 table is service-role-only at the RLS layer.
	//
	// FLAG-GATED OFF = PARITY: compliance.Mount is called ONLY when
	// SOC2_EVIDENCE_ENABLED is truthy. When OFF (the default) Mount is never
	// called, so none of the /v1/compliance* routes are registered (404) and the
	// collector never runs, so no compliance_evidence row is ever written — byte-
	// identical to today, the same discipline as TENANT_AUDIT_ENABLED /
	// HARD_ERASE_ENABLED / ORG_MODEL_ENABLED above.
	if envBool("SOC2_EVIDENCE_ENABLED") {
		complianceSvc := compliance.NewService(db)
		compliance.Mount(mux, complianceSvc, cfg.ServiceToken)
		// OPTIONAL scheduled snapshots: a no-op unless SOC2_EVIDENCE_SCHEDULE is a
		// positive duration (default empty = today's on-demand-only behavior). The
		// ticker stops on ctx cancel (shutdown). Only reachable here, behind the flag.
		complianceSvc.StartScheduler(ctx)
		log.Info("SOC2-lite compliance evidence collector enabled (/v1/compliance/collect|evidence|verify) — SOC2_EVIDENCE_ENABLED")
	} else {
		log.Info("SOC2-lite compliance evidence collector disabled (SOC2_EVIDENCE_ENABLED off) — /v1/compliance* not mounted")
	}
	// ─── end D4.1 ───────────────────────────────────────────────────────────────

	// ─── Track-D D4.3: TENANT DATA EXPORT (GDPR data portability) ──────────────
	// A PORTABLE bundle of ONE tenant's data — a single self-describing JSON
	// document (per-table rows + a manifest{tables, row counts, sha256}) the tenant
	// can take ELSEWHERE (GDPR Art. 20). It builds on B6 backup's data-SCOPING but
	// the OUTPUT differs in kind: B6 produces a restore-oriented COPY artifact;
	// D4.3 produces a portable, engine-neutral JSON bundle (no restore lifecycle).
	//   admin:  POST /v1/tenants/{id}/export · GET .../exports · GET .../export/{exportId}
	//   self:   POST/GET /v1/tenants/me/export(s) · GET /v1/tenants/me/export/{exportId}
	//
	// SCOPED STRICTLY TO ONE TENANT (reusing the D4.4 erase resolution):
	// schema_per_tenant => that tenant's OWN schema (tenants.TenantSchema); every
	// BASE TABLE. shared_rls => the shared data tables, each filtered WHERE
	// tenant_id = the caller's slug (never a bare scan of a shared table). So the
	// bundle can NEVER contain another tenant's rows. db_per_tenant + tenant_owned
	// are DEFERRED (400). Migration 052 backs the tenant_exports ledger.
	//
	// FLAG-GATED OFF = PARITY: export.Mount is called ONLY when TENANT_EXPORT_ENABLED
	// is truthy. When OFF (the default) Mount is never called, so none of the export
	// routes are registered (404) and no tenant_exports row is ever written — byte-
	// identical to today, the same discipline as TENANT_BACKUP_ENABLED /
	// HARD_ERASE_ENABLED above. The artifact store init fails fast (a misconfigured
	// store is a data-safety boundary) but only along this opt-in path. The
	// self-serve surface is narrowed by a SECOND flag, TENANT_SELFSERVE_ENABLED
	// (the tenants Service is the key->tenant resolver), exactly as backup narrows
	// its self-serve surface.
	if envBool("TENANT_EXPORT_ENABLED") {
		estore, err := export.NewStoreFromEnv()
		if err != nil {
			log.Error("export: artifact store init failed", "err", err)
			os.Exit(1)
		}
		esvc := export.NewService(db, estore, log)
		export.Mount(mux, esvc, cfg.ServiceToken)
		if envBool("TENANT_SELFSERVE_ENABLED") {
			export.MountSelfServe(mux, esvc.WithTenants(svc), esvc)
			log.Info("tenant data-export self-serve enabled (/v1/tenants/me/export(s), API-key)")
		}
		log.Info("tenant data-export API enabled (/v1/tenants/{id}/export|exports) — TENANT_EXPORT_ENABLED")
	} else {
		log.Info("tenant data-export disabled (TENANT_EXPORT_ENABLED off) — /v1/tenants/{id}/export* not mounted")
	}
	// ─── end D4.3 ───────────────────────────────────────────────────────────────

	// ─── Track-D D2c: PASSKEYS / WebAuthn (server-side ceremonies) ─────────────
	// Net-new enterprise auth: gotrue has NO passkey support. A server-side
	// WebAuthn relying party drives a registration ceremony (BeginRegistration ->
	// authenticator -> FinishRegistration, store the credential) and an
	// authentication ceremony (BeginLogin -> authenticator signs the challenge ->
	// FinishLogin, verify the assertion against the stored COSE public key, bump
	// the sign_count, mint a GoTrue-shaped session JWT). The cryptography is the
	// maintained github.com/go-webauthn/webauthn library's; the control plane owns
	// the durable credential store (migration 050), the short-TTL server-side
	// challenge state, and the session mint (the SAME HS256 secret/claim shape the
	// existing tenants.JWTVerifier accepts, so a passkey session == a password
	// session). Routes: POST /v1/auth/passkeys/{register,login}/{begin,finish}.
	//
	// FLAG-GATED OFF = PARITY: passkeys.Mount is called ONLY when PASSKEYS_ENABLED
	// is truthy. When OFF (the default) Mount is never called, so none of the
	// /v1/auth/passkeys/* routes are registered (404) and the webauthn_credentials
	// table is never consulted — byte-identical to today, the same discipline as
	// TENANT_AUDIT_ENABLED / HARD_ERASE_ENABLED / ORG_MODEL_ENABLED above.
	//
	// The session mint REQUIRES the shared GoTrue secret (a passkey login issues a
	// real session); if no GOTRUE_JWT_SECRET/JWT_SECRET is set the API cannot mint
	// and boot fails fast on this opt-in path (a passkey login that cannot issue a
	// session is a misconfiguration, not a silent no-op). PASSKEYS_RP_ID /
	// PASSKEYS_RP_ORIGINS configure the relying party (the origin bind is part of
	// why a stolen assertion cannot be replayed against another site).
	if envBool("PASSKEYS_ENABLED") {
		if jwtSecret == "" {
			log.Error("passkeys: PASSKEYS_ENABLED requires GOTRUE_JWT_SECRET/JWT_SECRET to mint a session")
			os.Exit(1)
		}
		rpID := envFirst("PASSKEYS_RP_ID", "WEBAUTHN_RP_ID")
		rpOrigins := splitCSV(envFirst("PASSKEYS_RP_ORIGINS", "WEBAUTHN_RP_ORIGINS"))
		if rpID == "" || len(rpOrigins) == 0 {
			log.Error("passkeys: PASSKEYS_RP_ID and PASSKEYS_RP_ORIGINS are required when PASSKEYS_ENABLED")
			os.Exit(1)
		}
		minter := passkeys.NewSessionMinter(jwtSecret, os.Getenv("GOTRUE_JWT_ISSUER"), 0)
		pkSvc, err := passkeys.NewService(db, passkeys.Config{
			RPID:          rpID,
			RPDisplayName: envOr("PASSKEYS_RP_DISPLAY_NAME", "Grobase"),
			RPOrigins:     rpOrigins,
		}, minter, log)
		if err != nil {
			log.Error("passkeys: relying-party init failed", "err", err)
			os.Exit(1)
		}
		passkeys.Mount(mux, pkSvc, cfg.ServiceToken)
		log.Info("passkeys / WebAuthn enabled (/v1/auth/passkeys/{register,login}/{begin,finish}) — PASSKEYS_ENABLED", "rp_id", rpID)
	} else {
		log.Info("passkeys / WebAuthn disabled (PASSKEYS_ENABLED off) — /v1/auth/passkeys/* not mounted")
	}
	// ─── end D2c ────────────────────────────────────────────────────────────────

	// ─── Track-D D2a: ENTERPRISE OIDC SSO (org-level) ──────────────────────────
	// Net-new enterprise auth: gotrue has NO org-level SSO. D2a adds an OIDC
	// authorization-code login driven by per-tenant IdP connections (migration
	// 053). begin -> the IdP authenticates the user -> callback exchanges the code,
	// VERIFIES the returned id_token (HS256 shared-secret OR RS256 via the IdP's
	// jwks_url), and mints a GoTrue-shaped session JWT — the SAME HS256 secret/claim
	// shape the existing tenants.JWTVerifier accepts, so an SSO session == a password
	// session. The client secret is stored AES-256-GCM SEALED (SSO_SECRET_KEY).
	// Routes: POST /v1/auth/sso/begin, GET|POST /v1/auth/sso/callback,
	// POST|GET /v1/tenants/{id}/sso/connections (service token).
	//
	// FLAG-GATED OFF = PARITY: sso.Mount is called ONLY when SSO_ENABLED is truthy.
	// When OFF (the default) Mount is never called, so none of the /v1/auth/sso/*
	// routes are registered (404) and sso_connections is never consulted — byte-
	// identical to today, the same discipline as PASSKEYS_ENABLED / TENANT_AUDIT_ENABLED
	// above. The session mint REQUIRES the shared GoTrue secret; if unset, boot fails
	// fast on this opt-in path (an SSO login that cannot issue a session is a
	// misconfiguration). SSO_SECRET_KEY seals the client secret; required when enabled.
	if envBool("SSO_ENABLED") {
		if jwtSecret == "" {
			log.Error("sso: SSO_ENABLED requires GOTRUE_JWT_SECRET/JWT_SECRET to mint a session")
			os.Exit(1)
		}
		sealer, err := sso.NewSecretSealerFromEnv()
		if err != nil {
			log.Error("sso: SSO_SECRET_KEY required when SSO_ENABLED", "err", err)
			os.Exit(1)
		}
		ssoSvc := sso.NewService(sso.NewStore(db, sealer),
			sso.NewSessionMinter(jwtSecret, os.Getenv("GOTRUE_JWT_ISSUER"), 0), log)
		sso.Mount(mux, ssoSvc, cfg.ServiceToken)
		log.Info("enterprise OIDC SSO enabled (/v1/auth/sso/*, /v1/tenants/{id}/sso/connections) — SSO_ENABLED")
	} else {
		log.Info("enterprise OIDC SSO disabled (SSO_ENABLED off) — /v1/auth/sso/* not mounted")
	}
	// ─── end D2a ──────────────────────────────────────────────────────────────

	// ─── Track-D D2b: SCIM 2.0 PROVISIONING (RFC 7644) ─────────────────────────
	// Net-new enterprise auth: gotrue has NO SCIM support. An enterprise IdP
	// (Okta / Entra / OneLogin) drives user lifecycle into Grobase over a BEARER
	// credential: POST/GET/PUT/PATCH/DELETE /scim/v2/Users. SCIM provisions ORG
	// MEMBERS — the humans above a project — so every provisioning op REUSES the
	// existing internal/orgs membership API (Add/Remove member); active:false
	// soft-deactivates (org_members.active=false), DELETE deprovisions. The bearer
	// token binds a tenant_id (+org_id) — that binding IS the per-tenant wall: a T1
	// token can never read or modify a user provisioned under T2.
	//
	// THE LOAD-BEARING CONSTRAINT (D-026): SCIM is a CONTROL-PLANE operation. It
	// NEVER enters RequestIdentity, the RLS GUCs, or the data plane. Per-request
	// isolation + SHARE_POOLS (24,887 tenants -> 1 pool) stay untouched. Migration
	// 054 backs the scim_tokens (sha256-hashed bearers) + scim_users mapping.
	//
	// FLAG-GATED OFF = PARITY: scim.Mount is called ONLY when SCIM_ENABLED is
	// truthy AND the org model is enabled (SCIM has no org to provision into
	// otherwise — orgs is its membership backend). When OFF (the default) Mount is
	// never called, so none of the /scim/v2/* routes are registered (404) and no
	// scim_tokens/scim_users row is ever written — byte-identical to today, the
	// same discipline as ORG_MODEL_ENABLED / PASSKEYS_ENABLED above.
	if envBool("SCIM_ENABLED") {
		if !envBool("ORG_MODEL_ENABLED") {
			log.Error("scim: SCIM_ENABLED requires ORG_MODEL_ENABLED (SCIM provisions org members)")
			os.Exit(1)
		}
		scimSvc := scim.NewService(db, orgs.NewService(db, log), log)
		scim.Mount(mux, scimSvc, cfg.ServiceToken)
		log.Info("SCIM 2.0 provisioning enabled (/scim/v2/Users + admin /v1/tenants/{id}/scim/tokens) — SCIM_ENABLED")
	} else {
		log.Info("SCIM 2.0 provisioning disabled (SCIM_ENABLED off) — /scim/v2/* not mounted")
	}
	// ─── end D2b ────────────────────────────────────────────────────────────────

	// ─── Track-D D4.6: TRUST CENTER (read-only public security posture) ─────────
	// A public-readable, FILE-BACKED security & compliance posture. The single
	// source is config/trust/posture.json (mounted RO via TRUST_MANIFEST, or the
	// byte-identical embedded copy when unset) — an array of controls each tagged
	// implemented|partial|planned with an evidence pointer (a gate mNN or a wiki/
	// doc). It is the machine-readable half of wiki/trust-center.md. NO database, NO
	// migration, NO secrets — the posture is the PUBLIC half of the security story,
	// so the routes need no auth (like a status page):
	//   GET /v1/trust            the full manifest (envelope + controls)
	//   GET /v1/trust/controls   {count, controls[]}
	//
	// HONESTY IS LOAD-BEARING: LoadManifest/EmbeddedManifest REJECT a control that
	// claims status=implemented with an empty evidence pointer (an unproven claim
	// must be partial/planned), so a malformed/dishonest manifest fails boot fast on
	// this opt-in path rather than serving an "all green" lie. The m112 gate proves
	// the served count == config/trust/posture.json's count (endpoint reflects the
	// file, not a stub) and the no-implemented-without-evidence rule.
	//
	// FLAG-GATED OFF = PARITY: trust.Mount is called ONLY when TRUST_CENTER_ENABLED
	// is truthy. When OFF (the default) Mount is never called, so /v1/trust* 404s —
	// byte-identical to today, the same discipline as SOC2_EVIDENCE_ENABLED /
	// TENANT_EXPORT_ENABLED / PASSKEYS_ENABLED above.
	if envBool("TRUST_CENTER_ENABLED") {
		var trustManifest *trust.Manifest
		if mp := envOr("TRUST_MANIFEST", ""); mp != "" {
			m, err := trust.LoadManifest(mp)
			if err != nil {
				log.Error("trust: posture manifest load failed", "path", mp, "err", err)
				os.Exit(1)
			}
			trustManifest = m
			log.Info("trust center enabled (/v1/trust, /v1/trust/controls) — TRUST_CENTER_ENABLED", "manifest", mp, "controls", len(m.Controls))
		} else {
			m, err := trust.EmbeddedManifest()
			if err != nil {
				log.Error("trust: embedded posture manifest invalid", "err", err)
				os.Exit(1)
			}
			trustManifest = m
			log.Info("trust center enabled (/v1/trust, /v1/trust/controls) — TRUST_CENTER_ENABLED (embedded manifest)", "controls", len(m.Controls))
		}
		trust.Mount(mux, trustManifest)
	} else {
		log.Info("trust center disabled (TRUST_CENTER_ENABLED off) — /v1/trust* not mounted")
	}
	// ─── end D4.6 ─────────────────────────────────────────────────────────────────

	// ─── Track-E: DB BRANCHING (Supabase-parity "branches") ─────────────────────
	// A tenant can fork a schema_per_tenant mount into a named, isolated SCHEMA-CLONE
	// (parent tables + a full row copy) for preview/staging — list and drop them.
	// Unlike B6 backup (a restore COPY artifact) or D4.3 export (a portable JSON
	// bundle), a branch is a LIVE schema sitting next to the parent in the SAME
	// control-plane Postgres: CREATE SCHEMA + per-table `CREATE TABLE (LIKE … INCLUDING
	// ALL)` + `INSERT … SELECT *`, all over the existing pgx pool (NO pg_dump).
	//   admin: POST /v1/tenants/{id}/branches · GET .../branches · DELETE .../branches/{branchId}
	// Branch names are validated to a safe [a-z0-9_] identifier (the SQL-identifier
	// injection wall, since the name flows into CREATE SCHEMA DDL). Only
	// schema_per_tenant is branchable; shared_rls / db_per_tenant / tenant_owned are
	// DEFERRED (400 "deferred"). Migration 055 backs the tenant_branches ledger.
	//
	// FLAG-GATED OFF = PARITY: branching.Mount is called ONLY when DB_BRANCHING_ENABLED
	// is truthy. When OFF (the default) Mount is never called, so the branch routes are
	// not registered (404) and no tenant_branches row is ever written — byte-identical
	// to today, the same discipline as TENANT_EXPORT_ENABLED / HARD_ERASE_ENABLED.
	if envBool("DB_BRANCHING_ENABLED") {
		branching.Mount(mux, branching.NewService(db, log), cfg.ServiceToken)
		log.Info("DB branching enabled (POST/GET /v1/tenants/{id}/branches, DELETE .../{branchId}) — DB_BRANCHING_ENABLED")
	} else {
		log.Info("DB branching disabled (DB_BRANCHING_ENABLED off) — /v1/tenants/{id}/branches* not mounted")
	}
	// ─── end Track-E DB branching ────────────────────────────────────────────────

	// ─── Track-E: PUSH / MESSAGING (Firebase FCM-parity) ───────────────────────
	// Net-new capability: a tenant registers delivery SUBSCRIPTIONS (channel
	// 'webhook' or 'fcm' — both are an outbound HTTP POST to a configured
	// target_url, so 'fcm' is a pluggable FCM-compatible endpoint, NO real FCM SDK
	// required) and SENDS a notification that fans out to every matching live
	// subscription. It reuses internal/webhooks' outbound-HTTP delivery discipline
	// (per-request timeout + an SSRF guard that REFUSES to POST to any private/
	// loopback/link-local/unspecified address — incl. 169.254.169.254, the cloud
	// metadata endpoint, and the in-cluster Postgres). A narrow operator allowlist
	// (PUSH_SSRF_ALLOW_HOSTS, default empty = nothing private allowed) permits naming
	// specific internal webhook targets for in-cluster delivery. A provider token
	// (for the fcm path) is stored AES-256-GCM SEALED (PUSH_SECRET_KEY; nil-safe).
	// Migration 056 backs public.push_subscriptions.
	//   admin: POST/GET /v1/tenants/{id}/push/subscriptions ·
	//          DELETE /v1/tenants/{id}/push/subscriptions/{subId} ·
	//          POST /v1/tenants/{id}/push/send {title,body}
	//
	// CONTROL-PLANE ONLY: push never enters RequestIdentity, the data-plane RLS GUCs,
	// or the data plane — tenant_id is bound in EVERY store query (the wall), so a
	// send in one tenant can never deliver to another tenant's subscriptions, and
	// per-request isolation + SHARE_POOLS (24,887 tenants -> 1 pool) stay untouched.
	//
	// FLAG-GATED OFF = PARITY: push.Mount is called ONLY when PUSH_ENABLED is truthy.
	// When OFF (the default) Mount is never called, so none of the /v1/tenants/{id}/
	// push/* routes are registered (404) and push_subscriptions is never written —
	// byte-identical to today, the same discipline as the blocks above.
	if envBool("PUSH_ENABLED") {
		push.Mount(mux, push.NewService(db, log), cfg.ServiceToken)
		log.Info("push / messaging enabled (/v1/tenants/{id}/push/subscriptions|send) — PUSH_ENABLED")
	} else {
		log.Info("push / messaging disabled (PUSH_ENABLED off) — /v1/tenants/{id}/push/* not mounted")
	}
	// ─── end Track-E push ─────────────────────────────────────────────────────────

	srv := &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           shared.WithMiddleware(mux, log),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Info("listening", "addr", cfg.ListenAddr(), "mode", cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
	log.Info("stopped")
}

func envFirst(keys ...string) string {
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return ""
}

// envBool reads a truthy env flag (mirrors metering.envBool). Default (unset or
// anything not truthy) is false — so a flag-gated path stays OFF unless
// explicitly enabled, which is the parity default.
func envBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "on", "TRUE", "True", "ON":
		return true
	default:
		return false
	}
}

// envOr returns the env value for key, or def when unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// splitCSV splits a comma-separated env value into trimmed, non-empty fields
// (e.g. PASSKEYS_RP_ORIGINS="https://app.example.com,https://example.com"). It
// avoids the strings import to keep main.go's import set untouched.
func splitCSV(s string) []string {
	out := []string{}
	cur := []rune{}
	flush := func() {
		// trim leading/trailing ASCII space from the field.
		start, end := 0, len(cur)
		for start < end && (cur[start] == ' ' || cur[start] == '\t') {
			start++
		}
		for end > start && (cur[end-1] == ' ' || cur[end-1] == '\t') {
			end--
		}
		if end > start {
			out = append(out, string(cur[start:end]))
		}
		cur = cur[:0]
	}
	for _, r := range s {
		if r == ',' {
			flush()
			continue
		}
		cur = append(cur, r)
	}
	flush()
	return out
}

func healthcheck(cfg shared.Config) int {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + cfg.Port + "/health/live")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
