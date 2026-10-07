/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   config.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package shared holds cross-service plumbing for the Go control plane:
// config loading, structured logging, the Postgres pool, and HTTP middleware.
package config

import "os"

// weakServiceToken is the placeholder older compose files defaulted to. A service
// must NOT boot with it (or an empty token): the internal service-token guard
// would then trust a publicly-known value, defeating control-plane auth. Compose
// no longer falls back to JWT_SECRET either: the token is its own secret.
const weakServiceToken = "dev-service-token-change-me"

// securityModeMax is the strict production posture. At this mode the control
// plane REQUIRES Vault-backed credentials and FAILS CLOSED (refuses to boot)
// when the master credential is absent or a well-known placeholder — there is
// no silent fallback to an env/default value. Any other value (default
// "baseline") leaves the boot path byte-identical to today. Enforcement lives in
// vaultcreds.go (requireVaultBackedCredentials).
const securityModeMax = "max"

// Config is the common runtime configuration for a control-plane service.
type Config struct {
	Host         string
	Port         string
	DatabaseURL  string
	ServiceToken string
	ProductMode  string
	// SecurityMode is the SECURITY_MODE posture (default "baseline"). Only
	// "max" activates the Vault-required fail-closed enforcement; every other
	// value keeps the boot path byte-identical to the live baseline.
	SecurityMode string
	// Environment is the GROBASE_ENV identity (default Local). In a Strict
	// environment (Staging, Prod) a missing required secret refuses to boot.
	Environment Environment
}

// LoadConfig reads <PREFIX>_HOST / <PREFIX>_PORT and shared DATABASE_URL.
// Example prefix: "ADAPTER_REGISTRY".
//
// GROBASE_ENV (default local) selects how strictly required secrets are
// enforced. An unknown value fails with ErrUnknownEnvironment. DATABASE_URL and
// INTERNAL_SERVICE_TOKEN are required in every environment; in staging and prod
// the prefix's own secrets are required too (requiredSecrets). Every missing key
// is reported together in one ErrMissingConfig error that names keys, never values.
//
// G-Vault (A6): at SECURITY_MODE=max the control plane REQUIRES a Vault-backed
// master credential and FAILS CLOSED here (a LoadConfig error → main() os.Exit(1))
// if it is absent or a repo-visible placeholder. The default ("baseline") mode
// short-circuits in requireVaultBackedCredentials, so the boot path stays
// byte-identical to today.
func LoadConfig(prefix string) (Config, error) {
	env, err := ParseEnvironment(os.Getenv(environmentKey))
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		Host:         EnvStr(prefix+"_HOST", "0.0.0.0"),
		Port:         EnvStr(prefix+"_PORT", "3021"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		ServiceToken: os.Getenv(serviceTokenKey),
		ProductMode:  EnvStr(prefix+"_PRODUCT_MODE", "shadow"),
		SecurityMode: EnvStr("SECURITY_MODE", "baseline"),
		Environment:  env,
	}
	if err := cfg.requireConfigured(prefix); err != nil {
		return Config{}, err
	}
	if err := requireVaultBackedCredentials(cfg.SecurityMode); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// IsMaxSecurity reports whether the strict production posture is active.
func (c Config) IsMaxSecurity() bool {
	return c.SecurityMode == securityModeMax
}

// ListenAddr returns host:port for http.Server.
func (c Config) ListenAddr() string {
	return c.Host + ":" + c.Port
}
