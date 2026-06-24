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

import (
	"fmt"
	"os"
)

// weakServiceToken is the compose default-of-last-resort. A service must NOT
// boot with it (or an empty token): the internal service-token guard would then
// trust a publicly-known value, defeating control-plane auth. The real fallback
// is JWT_SECRET (a strong secret), which is accepted.
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
}

// LoadConfig reads <PREFIX>_HOST / <PREFIX>_PORT and shared DATABASE_URL.
// Example prefix: "ADAPTER_REGISTRY".
//
// G-Vault (A6): at SECURITY_MODE=max the control plane REQUIRES a Vault-backed
// master credential and FAILS CLOSED here (a LoadConfig error → main() os.Exit(1))
// if it is absent or a repo-visible placeholder. The default ("baseline") mode
// short-circuits in requireVaultBackedCredentials, so the boot path stays
// byte-identical to today.
func LoadConfig(prefix string) (Config, error) {
	cfg := Config{
		Host:         EnvStr(prefix+"_HOST", "0.0.0.0"),
		Port:         EnvStr(prefix+"_PORT", "3021"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		ServiceToken: os.Getenv("INTERNAL_SERVICE_TOKEN"),
		ProductMode:  EnvStr(prefix+"_PRODUCT_MODE", "shadow"),
		SecurityMode: EnvStr("SECURITY_MODE", "baseline"),
	}
	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.ServiceToken == "" || cfg.ServiceToken == weakServiceToken {
		return Config{}, fmt.Errorf(
			"INTERNAL_SERVICE_TOKEN must be set to a strong value (refusing empty or the placeholder %q); "+
				"the live stack derives it from JWT_SECRET — set JWT_SECRET or ADAPTER_REGISTRY_SERVICE_TOKEN",
			weakServiceToken,
		)
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
