package main

import (
	"context"
	"log/slog"
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// buildService constructs the adapterregistry service and applies the two
// flag-gated layers (CMEK, dynamic builder), then ensures the schema. Both
// flags default OFF = byte-parity.
func buildService(ctx context.Context, db *pg.Postgres, log *slog.Logger) *adapterregistry.Service {
	enc, err := adapterregistry.NewEncryptor(os.Getenv("VAULT_ENC_KEY"))
	if err != nil {
		log.Error("encryptor init failed", "err", err)
		os.Exit(1)
	}
	svc := adapterregistry.NewService(db, enc, log)
	applyCMEK(svc, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		log.Error("ensure schema failed", "err", err)
		os.Exit(1)
	}
	applyBuilder(svc, db, log)
	return svc
}

// applyCMEK wires CMEK / BYOK (D4.8) — FLAG-GATED OFF = PARITY. When CMEK_ENABLED
// is off (the default) SetCMEK is never called, the provider stays nil, and
// Register/GetConnection take the EXACT existing inline-AES-GCM / cred-ref paths,
// byte-identical to the m121/S2 baseline. When on, an inline mount is envelope-
// sealed: a fresh DEK encrypts the DSN and an EXTERNAL KMS (Vault Transit, or a
// test-only local KEK) WRAPS the DEK. The platform stores only the wrapped DEK +
// ciphertext and cannot decrypt without the KMS (revoke the KMS key ⇒ crypto-
// shred). CMEK lives entirely here in the control plane — it never enters the
// Rust data plane / pool key, so SHARE_POOLS density is untouched.
func applyCMEK(svc *adapterregistry.Service, log *slog.Logger) {
	if !config.EnvBool("CMEK_ENABLED") {
		log.Info("CMEK / BYOK disabled (CMEK_ENABLED off) — inline DSNs use the platform master key (byte-parity)")
		return
	}
	provider, defaultKey, err := buildKMSProvider()
	if err != nil {
		log.Error("cmek: provider init failed", "err", err)
		os.Exit(1)
	}
	svc.SetCMEK(true, provider, defaultKey)
	log.Info("CMEK / BYOK enabled (envelope-encrypt inline DSNs via external KMS) — CMEK_ENABLED",
		"provider", os.Getenv("CMEK_KMS_PROVIDER"), "default_key", defaultKey)
}

// applyBuilder wires the dynamic builder (BUILDER_ENABLED) — FLAG-GATED OFF =
// PARITY. When unset (the default) SetResolver is never called, so
// packageForTenant resolves the tenant's plan via the embedded manifest verbatim
// and the /connect stamp + engine allowlist + max_mounts are byte-identical to
// today. When ON, the EFFECTIVE per-tenant package (the custom entitlement
// clamped to its ceiling) is what gets stamped/enforced — a pure control-plane
// resolver swap, ZERO Rust changes. The resolver reads public.tenant_entitlements
// (migration 062); requires the same table tenant-control's builder API writes.
// Resolve CLAMPS on every read, so even a stale over-ceiling row can never widen
// the stamp.
func applyBuilder(svc *adapterregistry.Service, db *pg.Postgres, log *slog.Logger) {
	if !config.EnvBool("BUILDER_ENABLED") {
		log.Info("dynamic builder disabled (BUILDER_ENABLED off) — /connect stamps the named tier verbatim (byte-parity)")
		return
	}
	manifest, err := packages.Load()
	if err != nil {
		log.Error("builder: package manifest load failed", "err", err)
		os.Exit(1)
	}
	resolver := entitlements.NewResolver(manifest, entitlements.NewStore(db), true, log)
	svc.SetResolver(resolver)
	log.Info("dynamic builder enabled (per-tenant entitlement resolver) — BUILDER_ENABLED; /connect stamps the EFFECTIVE clamped package")
}
