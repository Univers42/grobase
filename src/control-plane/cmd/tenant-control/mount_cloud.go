package main

import (
	"context"
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/abuseguard"
	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/erase"
	"github.com/dlesieur/mini-baas/control-plane/internal/ipguard"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// mountAbuse mounts the free-tier abuse/KYC-lite guard (ABUSE_GUARD_ENABLED).
// OFF = no Redis connect, no routes, no principal_events row (byte-parity).
func (b *bootCtx) mountAbuse(ctx context.Context) {
	ag := abuseguard.NewGuard(b.log, b.db, b.cfg.ServiceToken)
	if !ag.Enabled() {
		b.log.Info("abuse guard disabled (ABUSE_GUARD_ENABLED off) — /v1/abuse/* not mounted")
		return
	}
	if err := ag.Init(ctx); err != nil {
		b.log.Error("abuse guard init failed", "err", err)
		os.Exit(1)
	}
	abuseguard.Mount(b.mux, ag)
	b.log.Info("abuse guard enabled (/v1/abuse/admit|suspend|unsuspend|state)")
}

// mountAudit mounts the D3 tamper-evident tenant audit log (TENANT_AUDIT_ENABLED).
func (b *bootCtx) mountAudit() {
	if !config.EnvBool("TENANT_AUDIT_ENABLED") {
		b.log.Info("tenant audit log disabled (TENANT_AUDIT_ENABLED off) — /v1/audit* not mounted")
		return
	}
	audit.Mount(b.mux, audit.NewService(b.db), b.cfg.ServiceToken)
	b.log.Info("tenant audit log enabled (/v1/audit/tenants/{id}/events|export|verify)")
}

// mountErase mounts the D4.4 hard-erase/teardown route (HARD_ERASE_ENABLED). The
// erase service reuses the D3 audit chain so the receipt is verifiable.
func (b *bootCtx) mountErase() {
	if !config.EnvBool("HARD_ERASE_ENABLED") {
		b.log.Info("hard-erase disabled (HARD_ERASE_ENABLED off) — /v1/tenants/{id}/erase not mounted; teardown is soft-delete only")
		return
	}
	erSvc := erase.NewService(b.db, audit.NewService(b.db), b.log)
	erSvc.SetKeyCacheFlusher(b.svc.FlushVerifyCache)
	erase.Mount(b.mux, erSvc, b.cfg.ServiceToken)
	b.log.Info("hard-erase enabled (POST /v1/tenants/{id}/erase) — HARD_ERASE_ENABLED")
}

// mountOrgs mounts the D1 organizations/RBAC layer (ORG_MODEL_ENABLED). A nil
// jwtVerifier is passed UNTYPED to keep the rt.jwt == nil guard honest: JWT is
// left as the zero (nil interface) when there is no verifier — assigning a
// typed-nil *JWTVerifier would make rt.jwt != nil and break the guard.
func (b *bootCtx) mountOrgs() {
	if !config.EnvBool("ORG_MODEL_ENABLED") {
		b.log.Info("organizations API disabled (ORG_MODEL_ENABLED off) — /v1/orgs* not mounted")
		return
	}
	osvc := orgs.NewService(b.db, b.log)
	d := orgs.Deps{Svc: osvc, TenantSvc: b.svc, Reconciler: b.reconciler, ServiceToken: b.cfg.ServiceToken}
	if b.jwtVerifier != nil {
		d.JWT = b.jwtVerifier
	}
	orgs.Mount(b.mux, d)
	b.log.Info("organizations API enabled (/v1/orgs*) — ORG_MODEL_ENABLED", "jwt", b.jwtVerifier != nil)
}

// mountIPGuard mounts the D2e tenant IP allowlist (TENANT_IP_ALLOWLIST_ENABLED),
// with self-serve CRUD only when TENANT_SELFSERVE_ENABLED is also truthy.
func (b *bootCtx) mountIPGuard() {
	if !config.EnvBool("TENANT_IP_ALLOWLIST_ENABLED") {
		b.log.Info("tenant IP allowlist disabled (TENANT_IP_ALLOWLIST_ENABLED off) — /v1/ipguard* + ip-allowlist routes not mounted")
		return
	}
	ipsvc := ipguard.NewService(b.db)
	ipguard.Mount(b.mux, ipsvc, b.cfg.ServiceToken)
	if config.EnvBool("TENANT_SELFSERVE_ENABLED") {
		ipguard.MountSelfServe(b.mux, ipsvc, b.svc)
		b.log.Info("ip-allowlist self-serve enabled (/v1/tenants/me/ip-allowlist, API-key)")
	}
	b.log.Info("tenant IP allowlist enabled (POST /v1/ipguard/check + /v1/tenants/{id}/ip-allowlist) — TENANT_IP_ALLOWLIST_ENABLED")
}
