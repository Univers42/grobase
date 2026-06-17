package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/backup"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/metering"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// mountCore registers the always-on tenant routes plus the metering read-back
// API (the READ path is unflagged — empty aggregates when metering is OFF).
func (b *bootCtx) mountCore() {
	tenants.Mount(b.mux, b.svc, b.cfg.ServiceToken, b.jwtVerifier, b.reconciler)
	metering.Mount(b.mux, b.db, b.cfg.ServiceToken)
}

// mountSelfServe mounts /v1/tenants/me* (TENANT_SELFSERVE_ENABLED) and, nested,
// the dynamic builder (BUILDER_ENABLED). FLAG-GATED OFF = byte-parity.
func (b *bootCtx) mountSelfServe() {
	if !config.EnvBool("TENANT_SELFSERVE_ENABLED") {
		b.log.Info("tenant self-service API disabled (TENANT_SELFSERVE_ENABLED off) — /v1/tenants/me* not mounted")
		return
	}
	manifest, err := packages.Load()
	if err != nil {
		b.log.Error("tenant self-serve: package manifest load failed", "err", err)
		os.Exit(1)
	}
	billing := config.EnvBool("BILLING_ENABLED")
	tenants.MountSelfServe(b.mux, b.svc, b.jwtVerifier, manifest, billing)
	b.log.Info("tenant self-service API enabled (/v1/tenants/me*)", "billing", billing)
	b.mountBuilder(manifest)
}

// mountBuilder mounts the dynamic-builder routes (BUILDER_ENABLED), nested under
// the self-serve block so it reuses selfAuth. OFF = builder routes 404 (parity).
func (b *bootCtx) mountBuilder(manifest *packages.Manifest) {
	if !config.EnvBool("BUILDER_ENABLED") {
		b.log.Info("dynamic builder disabled (BUILDER_ENABLED off) — builder routes not mounted; resolution is the named tier verbatim (byte-parity)")
		return
	}
	builderStore := entitlements.NewStore(b.db)
	tenants.MountBuilder(b.mux, b.svc, b.jwtVerifier, builderStore, manifest, b.svc.AdapterClient(), b.cfg.ServiceToken)
	b.log.Info("dynamic builder enabled (/v1/tenants/me/{mounts,entitlements,builder} + operator /v1/tenants/{id}/{ceiling,entitlement}) — BUILDER_ENABLED",
		"adapter", b.svc.AdapterClient() != nil)
}

// mountBackup mounts the per-tenant backup/restore API (TENANT_BACKUP_ENABLED),
// with an optional read-only self-serve route (TENANT_BACKUP_SELFSERVE_ENABLED).
func (b *bootCtx) mountBackup() {
	if !config.EnvBool("TENANT_BACKUP_ENABLED") {
		b.log.Info("per-tenant backup/restore API disabled (TENANT_BACKUP_ENABLED off) — routes not mounted")
		return
	}
	store, err := backup.NewStoreFromEnv()
	if err != nil {
		b.log.Error("backup: artifact store init failed", "err", err)
		os.Exit(1)
	}
	bsvc := backup.NewService(b.db, store, b.log)
	backup.Mount(b.mux, bsvc, b.cfg.ServiceToken)
	if config.EnvBool("TENANT_BACKUP_SELFSERVE_ENABLED") {
		backup.MountSelfServe(b.mux, bsvc, b.svc)
		b.log.Info("tenant backup self-serve read enabled (/v1/tenants/me/backups, API-key)")
	}
	b.log.Info("per-tenant backup/restore API enabled (/v1/tenants/{id}/backup|backups|restore)")
}
