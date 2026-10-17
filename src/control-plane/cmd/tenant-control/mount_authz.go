package main

import (
	"github.com/dlesieur/mini-baas/control-plane/internal/authz"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// mountAuthz mounts the relationship-authz routes (AUTHZ_ENABLED): PUT/GET the app's model, replace
// a source's tuples, and check / check-batch. Authentication is a tenant API key ONLY (a GoTrue JWT
// is 401) and the app is the key's tenant slug. AUTHZ_MAX_CONCURRENT bounds the checks that hold a
// database connection at once. OFF ⇒ no /v1/authz routes (404 = byte-parity with the OSS edition).
func (b *bootCtx) mountAuthz() {
	if !config.EnvBool("AUTHZ_ENABLED") {
		b.log.Info("authz disabled (AUTHZ_ENABLED off) — routes not mounted")
		return
	}
	cfg := authz.DefaultConfig()
	cfg.MaxConcurrent = config.EnvInt("AUTHZ_MAX_CONCURRENT", cfg.MaxConcurrent)
	authz.Mount(b.mux, authz.Deps{
		Svc:  authz.NewStore(b.db, b.log, cfg),
		Auth: tenants.NewSelfAuthenticator(b.svc, b.jwtVerifier),
		Log:  b.log,
	})
	b.log.Info("authz enabled (/v1/authz) — AUTHZ_ENABLED", "max_concurrent", cfg.MaxConcurrent)
}
