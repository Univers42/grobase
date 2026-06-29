/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   github.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:07 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:09 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package github implements Track-E GitHub App connect / device-flow login / org
// sync — the fly token-exchange side of the Vercel-relay topology. It holds the App
// private key (a runtime secret), mints short-lived installation tokens JUST IN TIME
// (never persisted), and stores ONLY the org↔installation↔user linkage. It maps a
// GitHub org's repos/teams/members into the vault42 org/RBAC model (delegating to
// orgs + teams), with GitHub the source of truth for structure and vault42 the final
// authority.
//
// CONTROL-PLANE ONLY (never enters the data plane). FLAG-GATED OFF = PARITY: the
// /v1/github* + /v1/orgs/{id}/github/* routes mount ONLY when GITHUB_CONNECT_ENABLED
// is truthy. The GitHub API / OAuth base URLs are injected (default github.com /
// api.github.com) so a gate can point them at a mock.
package github

import (
	"os"
	"strings"
)

// githubErr is the package's const-error type (typed string constant; errors.Is works).
type githubErr string

func (e githubErr) Error() string { return string(e) }

const (
	// ErrNotFound — a linkage / installation / pending row does not exist (404).
	ErrNotFound githubErr = "not found"
	// ErrRelayAuth — the Vercel relay forward HMAC did not verify (401).
	ErrRelayAuth githubErr = "relay signature invalid"
	// ErrConflict — already linked (409).
	ErrConflict githubErr = "already linked"
	// ErrPending — the device authorization is still pending (caller should retry).
	ErrPending githubErr = "authorization_pending"
	// ErrUpstream — a GitHub API call failed (502).
	ErrUpstream githubErr = "github upstream error"
	// ErrConfig — a required runtime secret/config is missing.
	ErrConfig githubErr = "github config incomplete"
)

// Config is the injected GitHub App + endpoint configuration (no globals). The App
// private key + client secret are runtime secrets, never logged or persisted.
type Config struct {
	AppID         string
	AppPrivateKey []byte // PEM (RS256 signer for the App JWT)
	ClientID      string
	ClientSecret  string
	RelaySecret   []byte // HMAC shared with the Vercel relay
	JWTSecret     []byte // GoTrue HS256 — mints the login session
	JWTIssuer     string
	APIBase       string // GitHub REST base, default https://api.github.com
	OAuthBase     string // GitHub OAuth/device base, default https://github.com
	DefaultRole   string // org role for synced members lacking a repo permission
}

// ConfigFromEnv reads the GitHub config from the environment, applying base-URL
// defaults. The App id + private key + relay + JWT secrets are required; their
// absence is ErrConfig (the mount fails fast).
func ConfigFromEnv() (Config, error) {
	cfg := Config{
		AppID:         os.Getenv("GITHUB_APP_ID"),
		AppPrivateKey: []byte(os.Getenv("GITHUB_APP_PRIVATE_KEY")),
		ClientID:      os.Getenv("GITHUB_APP_CLIENT_ID"),
		ClientSecret:  os.Getenv("GITHUB_APP_CLIENT_SECRET"),
		RelaySecret:   []byte(os.Getenv("GITHUB_RELAY_SECRET")),
		JWTSecret:     []byte(os.Getenv("GOTRUE_JWT_SECRET")),
		JWTIssuer:     os.Getenv("GOTRUE_JWT_ISSUER"),
		APIBase:       envOr("GITHUB_API_BASE", "https://api.github.com"),
		OAuthBase:     envOr("GITHUB_OAUTH_BASE", "https://github.com"),
		DefaultRole:   envOr("GITHUB_SYNC_DEFAULT_ROLE", "developer"),
	}
	if cfg.AppID == "" || len(cfg.AppPrivateKey) == 0 || len(cfg.RelaySecret) == 0 || len(cfg.JWTSecret) == 0 {
		return Config{}, ErrConfig
	}
	cfg.APIBase = strings.TrimRight(cfg.APIBase, "/")
	cfg.OAuthBase = strings.TrimRight(cfg.OAuthBase, "/")
	return cfg, nil
}

// envOr reads an env var with a fallback default.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Installation is the non-secret GitHub App installation identity.
type Installation struct {
	InstallationID int64          `json:"installation_id"`
	OrgLogin       string         `json:"github_org_login"`
	OrgID          int64          `json:"github_org_id"`
	AppSlug        string         `json:"app_slug"`
	Permissions    map[string]any `json:"permissions"`
}

// ConnectStatus is the CLI poll response for a pending connect.
type ConnectStatus struct {
	Status         string `json:"status"`
	InstallationID int64  `json:"installation_id,omitempty"`
	OrgLogin       string `json:"github_org_login,omitempty"`
}

// DeviceStart is the device-flow start response (relayed from GitHub).
type DeviceStart struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri"`
	ExpiresIn       int    `json:"expires_in"`
	Interval        int    `json:"interval"`
}

// SyncSummary reports what a github sync mapped into the vault42 model.
type SyncSummary struct {
	Teams       int `json:"teams"`
	Members     int `json:"members"`
	Repos       int `json:"repos"`
	RolesSeeded int `json:"roles_seeded"`
}
