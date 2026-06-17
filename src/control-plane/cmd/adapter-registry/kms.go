package main

import (
	"fmt"
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
)

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
		return vaultTransitProvider(defaultKey)
	case "local":
		seed := os.Getenv("CMEK_LOCAL_KEK_SEED")
		if seed == "" {
			seed = "cmek-local-default-seed"
		}
		return cmek.NewLocalKMSProvider(seed, defaultKey), defaultKey, nil
	default:
		return nil, "", fmt.Errorf("unknown CMEK_KMS_PROVIDER %q (want vault-transit|local)", os.Getenv("CMEK_KMS_PROVIDER"))
	}
}

// vaultTransitProvider builds the Vault Transit KMS provider from env.
func vaultTransitProvider(defaultKey string) (cmek.KMSProvider, string, error) {
	p, err := cmek.NewVaultTransitProvider(cmek.VaultTransitConfig{
		Addr:  os.Getenv("VAULT_ADDR"),
		Token: os.Getenv("VAULT_TOKEN"),
		Mount: os.Getenv("VAULT_TRANSIT_MOUNT"),
	})
	if err != nil {
		return nil, "", err
	}
	return p, defaultKey, nil
}
