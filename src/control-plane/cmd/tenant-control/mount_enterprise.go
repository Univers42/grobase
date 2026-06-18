package main

import (
	"context"
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/compliance"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/export"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
	"github.com/dlesieur/mini-baas/control-plane/internal/scim"
	"github.com/dlesieur/mini-baas/control-plane/internal/sso"
)

// mountCompliance mounts the D4.1 SOC2-lite evidence collector
// (SOC2_EVIDENCE_ENABLED), platform-level admin-only (service token).
func (b *bootCtx) mountCompliance(ctx context.Context) {
	if !config.EnvBool("SOC2_EVIDENCE_ENABLED") {
		b.log.Info("SOC2-lite compliance evidence collector disabled (SOC2_EVIDENCE_ENABLED off) — /v1/compliance* not mounted")
		return
	}
	complianceSvc := compliance.NewService(b.db)
	compliance.Mount(b.mux, complianceSvc, b.cfg.ServiceToken)
	complianceSvc.StartScheduler(ctx)
	b.log.Info("SOC2-lite compliance evidence collector enabled (/v1/compliance/collect|evidence|verify) — SOC2_EVIDENCE_ENABLED")
}

// mountExport mounts the D4.3 tenant data-export API (TENANT_EXPORT_ENABLED),
// with self-serve narrowed by TENANT_SELFSERVE_ENABLED.
func (b *bootCtx) mountExport() {
	if !config.EnvBool("TENANT_EXPORT_ENABLED") {
		b.log.Info("tenant data-export disabled (TENANT_EXPORT_ENABLED off) — /v1/tenants/{id}/export* not mounted")
		return
	}
	estore, err := export.NewStoreFromEnv()
	if err != nil {
		b.log.Error("export: artifact store init failed", "err", err)
		os.Exit(1)
	}
	esvc := export.NewService(b.db, estore, b.log)
	export.Mount(b.mux, esvc, b.cfg.ServiceToken)
	if config.EnvBool("TENANT_SELFSERVE_ENABLED") {
		export.MountSelfServe(b.mux, esvc.WithTenants(b.svc), esvc)
		b.log.Info("tenant data-export self-serve enabled (/v1/tenants/me/export(s), API-key)")
	}
	b.log.Info("tenant data-export API enabled (/v1/tenants/{id}/export|exports) — TENANT_EXPORT_ENABLED")
}

// mountSSO mounts the D2a enterprise OIDC SSO (SSO_ENABLED). Requires the shared
// GoTrue secret (session mint) and SSO_SECRET_KEY (client-secret sealing).
func (b *bootCtx) mountSSO() {
	if !config.EnvBool("SSO_ENABLED") {
		b.log.Info("enterprise OIDC SSO disabled (SSO_ENABLED off) — /v1/auth/sso/* not mounted")
		return
	}
	if b.jwtSecret == "" {
		b.log.Error("sso: SSO_ENABLED requires GOTRUE_JWT_SECRET/JWT_SECRET to mint a session")
		os.Exit(1)
	}
	sealer, err := sso.NewSecretSealerFromEnv()
	if err != nil {
		b.log.Error("sso: SSO_SECRET_KEY required when SSO_ENABLED", "err", err)
		os.Exit(1)
	}
	minter := sso.NewSessionMinter(b.jwtSecret, os.Getenv("GOTRUE_JWT_ISSUER"), 0)
	ssoSvc := sso.NewService(sso.NewStore(b.db, sealer), minter, b.log)
	sso.Mount(b.mux, ssoSvc, b.cfg.ServiceToken)
	b.log.Info("enterprise OIDC SSO enabled (/v1/auth/sso/*, /v1/tenants/{id}/sso/connections) — SSO_ENABLED")
}

// mountSCIM mounts the D2b SCIM 2.0 provisioning API (SCIM_ENABLED). Requires
// ORG_MODEL_ENABLED (orgs is the membership backend SCIM provisions into).
func (b *bootCtx) mountSCIM() {
	if !config.EnvBool("SCIM_ENABLED") {
		b.log.Info("SCIM 2.0 provisioning disabled (SCIM_ENABLED off) — /scim/v2/* not mounted")
		return
	}
	if !config.EnvBool("ORG_MODEL_ENABLED") {
		b.log.Error("scim: SCIM_ENABLED requires ORG_MODEL_ENABLED (SCIM provisions org members)")
		os.Exit(1)
	}
	scimSvc := scim.NewService(b.db, orgs.NewService(b.db, b.log), b.log)
	scim.Mount(b.mux, scimSvc, b.cfg.ServiceToken)
	b.log.Info("SCIM 2.0 provisioning enabled (/scim/v2/Users + admin /v1/tenants/{id}/scim/tokens) — SCIM_ENABLED")
}
