package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/branching"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/passkeys"
	"github.com/dlesieur/mini-baas/control-plane/internal/push"
	"github.com/dlesieur/mini-baas/control-plane/internal/trust"
)

// mountPasskeys mounts the D2c WebAuthn ceremonies (PASSKEYS_ENABLED). Requires
// the shared GoTrue secret (session mint) plus a configured relying party.
func (b *bootCtx) mountPasskeys() {
	if !config.EnvBool("PASSKEYS_ENABLED") {
		b.log.Info("passkeys / WebAuthn disabled (PASSKEYS_ENABLED off) — /v1/auth/passkeys/* not mounted")
		return
	}
	if b.jwtSecret == "" {
		b.log.Error("passkeys: PASSKEYS_ENABLED requires GOTRUE_JWT_SECRET/JWT_SECRET to mint a session")
		os.Exit(1)
	}
	rpID, rpOrigins := b.passkeysRP()
	minter := passkeys.NewSessionMinter(b.jwtSecret, os.Getenv("GOTRUE_JWT_ISSUER"), 0)
	pkSvc, err := passkeys.NewService(b.db, passkeys.Config{
		RPID: rpID, RPDisplayName: config.EnvStr("PASSKEYS_RP_DISPLAY_NAME", "Grobase"), RPOrigins: rpOrigins,
	}, minter, b.log)
	if err != nil {
		b.log.Error("passkeys: relying-party init failed", "err", err)
		os.Exit(1)
	}
	passkeys.Mount(b.mux, pkSvc, b.cfg.ServiceToken)
	b.log.Info("passkeys / WebAuthn enabled (/v1/auth/passkeys/{register,login}/{begin,finish}) — PASSKEYS_ENABLED", "rp_id", rpID)
}

// passkeysRP resolves the relying-party id + origins, exiting fatally when either
// is missing — verbatim the validation the original main() inlined.
func (b *bootCtx) passkeysRP() (string, []string) {
	rpID := envFirst("PASSKEYS_RP_ID", "WEBAUTHN_RP_ID")
	rpOrigins := splitCSV(envFirst("PASSKEYS_RP_ORIGINS", "WEBAUTHN_RP_ORIGINS"))
	if rpID == "" || len(rpOrigins) == 0 {
		b.log.Error("passkeys: PASSKEYS_RP_ID and PASSKEYS_RP_ORIGINS are required when PASSKEYS_ENABLED")
		os.Exit(1)
	}
	return rpID, rpOrigins
}

// mountTrust mounts the D4.6 read-only trust center (TRUST_CENTER_ENABLED) from a
// file manifest (TRUST_MANIFEST) or the embedded copy when unset.
func (b *bootCtx) mountTrust() {
	if !config.EnvBool("TRUST_CENTER_ENABLED") {
		b.log.Info("trust center disabled (TRUST_CENTER_ENABLED off) — /v1/trust* not mounted")
		return
	}
	if mp := config.EnvStr("TRUST_MANIFEST", ""); mp != "" {
		m, err := trust.LoadManifest(mp)
		if err != nil {
			b.log.Error("trust: posture manifest load failed", "path", mp, "err", err)
			os.Exit(1)
		}
		b.log.Info("trust center enabled (/v1/trust, /v1/trust/controls) — TRUST_CENTER_ENABLED", "manifest", mp, "controls", len(m.Controls))
		trust.Mount(b.mux, m)
		return
	}
	m, err := trust.EmbeddedManifest()
	if err != nil {
		b.log.Error("trust: embedded posture manifest invalid", "err", err)
		os.Exit(1)
	}
	b.log.Info("trust center enabled (/v1/trust, /v1/trust/controls) — TRUST_CENTER_ENABLED (embedded manifest)", "controls", len(m.Controls))
	trust.Mount(b.mux, m)
}

// mountBranching mounts the Track-E DB-branching API (DB_BRANCHING_ENABLED).
func (b *bootCtx) mountBranching() {
	if !config.EnvBool("DB_BRANCHING_ENABLED") {
		b.log.Info("DB branching disabled (DB_BRANCHING_ENABLED off) — /v1/tenants/{id}/branches* not mounted")
		return
	}
	branching.Mount(b.mux, branching.NewService(b.db, b.log), b.cfg.ServiceToken)
	b.log.Info("DB branching enabled (POST/GET /v1/tenants/{id}/branches, DELETE .../{branchId}) — DB_BRANCHING_ENABLED")
}

// mountPush mounts the Track-E push/messaging API (PUSH_ENABLED).
func (b *bootCtx) mountPush() {
	if !config.EnvBool("PUSH_ENABLED") {
		b.log.Info("push / messaging disabled (PUSH_ENABLED off) — /v1/tenants/{id}/push/* not mounted")
		return
	}
	push.Mount(b.mux, push.NewService(b.db, b.log, b.m), b.cfg.ServiceToken)
	b.log.Info("push / messaging enabled (/v1/tenants/{id}/push/subscriptions|send) — PUSH_ENABLED")
}
