// Package main boots the Go control-plane adapter-registry service.
//
// This is the control-plane replacement for the NestJS adapter-registry app.
// It owns the tenant database registry: encrypted connection-string storage
// (AES-256-GCM, byte-compatible with the legacy Node CryptoService) and the
// metadata CRUD that the Rust data plane resolves mounts against.
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func main() {
	log := shared.NewLogger("adapter-registry")

	cfg, err := shared.LoadConfig("ADAPTER_REGISTRY")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}

	// --healthcheck mode: used by the container HEALTHCHECK without a shell.
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

	encKey := os.Getenv("VAULT_ENC_KEY")
	enc, err := adapterregistry.NewEncryptor(encKey)
	if err != nil {
		log.Error("encryptor init failed", "err", err)
		os.Exit(1)
	}

	svc := adapterregistry.NewService(db, enc, log)

	// CMEK / BYOK (D4.8) — FLAG-GATED OFF = PARITY. When CMEK_ENABLED is off (the
	// default) SetCMEK is never called, the provider stays nil, and Register/
	// GetConnection take the EXACT existing inline-AES-GCM / cred-ref paths,
	// byte-identical to the m121/S2 baseline. When on, an inline mount is envelope-
	// sealed: a fresh DEK encrypts the DSN and an EXTERNAL KMS (Vault Transit, or
	// a test-only local KEK) WRAPS the DEK. The platform stores only the wrapped
	// DEK + ciphertext and cannot decrypt without the KMS (revoke the KMS key ⇒
	// crypto-shred). CMEK lives entirely here in the control plane — it never
	// enters the Rust data plane / pool key, so SHARE_POOLS density is untouched.
	if envBool("CMEK_ENABLED") {
		provider, defaultKey, cErr := buildKMSProvider()
		if cErr != nil {
			log.Error("cmek: provider init failed", "err", cErr)
			os.Exit(1)
		}
		svc.SetCMEK(true, provider, defaultKey)
		log.Info("CMEK / BYOK enabled (envelope-encrypt inline DSNs via external KMS) — CMEK_ENABLED",
			"provider", os.Getenv("CMEK_KMS_PROVIDER"), "default_key", defaultKey)
	} else {
		log.Info("CMEK / BYOK disabled (CMEK_ENABLED off) — inline DSNs use the platform master key (byte-parity)")
	}

	if err := svc.EnsureSchema(ctx); err != nil {
		log.Error("ensure schema failed", "err", err)
		os.Exit(1)
	}

	// Dynamic builder (BUILDER_ENABLED) — FLAG-GATED OFF = PARITY. When unset (the
	// default) SetResolver is never called, so packageForTenant resolves the
	// tenant's plan via the embedded manifest verbatim and the /connect stamp +
	// engine allowlist + max_mounts are byte-identical to today. When ON, the
	// EFFECTIVE per-tenant package (the custom entitlement clamped to its ceiling)
	// is what gets stamped/enforced — a pure control-plane resolver swap, ZERO
	// Rust changes. The resolver reads public.tenant_entitlements (migration 062);
	// requires the same table tenant-control's builder API writes. Resolve CLAMPS
	// on every read, so even a stale over-ceiling row can never widen the stamp.
	if envBool("BUILDER_ENABLED") {
		manifest, mErr := packages.Load()
		if mErr != nil {
			log.Error("builder: package manifest load failed", "err", mErr)
			os.Exit(1)
		}
		resolver := entitlements.NewResolver(manifest, entitlements.NewStore(db), true, log)
		svc.SetResolver(resolver)
		log.Info("dynamic builder enabled (per-tenant entitlement resolver) — BUILDER_ENABLED; /connect stamps the EFFECTIVE clamped package")
	} else {
		log.Info("dynamic builder disabled (BUILDER_ENABLED off) — /connect stamps the named tier verbatim (byte-parity)")
	}

	mux := shared.NewRouter("adapter-registry", db)
	adapterregistry.Mount(mux, svc, cfg.ServiceToken)

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

// envBool reads a truthy env flag (default OFF = parity), mirroring the
// tenant-control main.go helper.
func envBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "on", "TRUE", "True", "ON":
		return true
	default:
		return false
	}
}

// buildKMSProvider constructs the CMEK KMS provider from env, returning the
// provider + the default KEK id (used when a register request omits kms_key_id).
//
//	CMEK_KMS_PROVIDER       vault-transit (default) | local
//	CMEK_VAULT_TRANSIT_KEY  the default Transit key id (also the local default key)
//	vault-transit:          VAULT_ADDR + VAULT_TOKEN (+ optional VAULT_TRANSIT_MOUNT)
//	local (TEST-ONLY):      CMEK_LOCAL_KEK_SEED seeds an in-process KEK — NEVER
//	                        production (the KEK lives in this process's memory).
func buildKMSProvider() (cmek.KMSProvider, string, error) {
	defaultKey := os.Getenv("CMEK_VAULT_TRANSIT_KEY")
	if defaultKey == "" {
		return nil, "", fmt.Errorf("CMEK_VAULT_TRANSIT_KEY (default KMS key id) is required when CMEK_ENABLED")
	}
	switch os.Getenv("CMEK_KMS_PROVIDER") {
	case "", "vault-transit":
		p, err := cmek.NewVaultTransitProvider(cmek.VaultTransitConfig{
			Addr:  os.Getenv("VAULT_ADDR"),
			Token: os.Getenv("VAULT_TOKEN"),
			Mount: os.Getenv("VAULT_TRANSIT_MOUNT"),
		})
		if err != nil {
			return nil, "", err
		}
		return p, defaultKey, nil
	case "local":
		// TEST-ONLY: an in-process AES KEK. Documented as non-production.
		seed := os.Getenv("CMEK_LOCAL_KEK_SEED")
		if seed == "" {
			seed = "cmek-local-default-seed"
		}
		return cmek.NewLocalKMSProvider(seed, defaultKey), defaultKey, nil
	default:
		return nil, "", fmt.Errorf("unknown CMEK_KMS_PROVIDER %q (want vault-transit|local)", os.Getenv("CMEK_KMS_PROVIDER"))
	}
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
