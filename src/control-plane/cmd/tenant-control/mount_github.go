/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mount_github.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:37:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:37:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/github"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
	"github.com/dlesieur/mini-baas/control-plane/internal/teams"
)

// mountGitHub mounts Track-E GitHub App connect / device-login / org-sync
// (GITHUB_CONNECT_ENABLED). Sync upserts orgs/teams, so it requires the org model +
// RBAC hierarchy. OFF ⇒ no /v1/github* or /v1/orgs/{id}/github/* routes (404 = parity).
func (b *bootCtx) mountGitHub() {
	if !config.EnvBool("GITHUB_CONNECT_ENABLED") {
		b.log.Info("github connect disabled (GITHUB_CONNECT_ENABLED off) — /v1/github* not mounted")
		return
	}
	if !config.EnvBool("ORG_MODEL_ENABLED") || !config.EnvBool("RBAC_HIERARCHY_ENABLED") {
		b.log.Error("github: GITHUB_CONNECT_ENABLED requires ORG_MODEL_ENABLED + RBAC_HIERARCHY_ENABLED (sync upserts orgs/teams)")
		os.Exit(1)
	}
	if b.jwtVerifier == nil {
		b.log.Error("github: GITHUB_CONNECT_ENABLED requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		os.Exit(1)
	}
	cfg, err := github.ConfigFromEnv()
	if err != nil {
		b.log.Error("github: config incomplete (need GITHUB_APP_ID/PRIVATE_KEY/RELAY_SECRET + GOTRUE_JWT_SECRET)", "err", err)
		os.Exit(1)
	}
	osvc := orgs.NewService(b.db, b.log)
	tsvc := teams.NewService(b.db, osvc, audit.NewService(b.db), b.log)
	gsvc := github.NewService(b.db, osvc, tsvc, cfg, b.log)
	auth := orgs.NewAuthorizer(osvc, b.jwtVerifier)
	github.Mount(b.mux, github.Deps{Svc: gsvc, Auth: auth})
	b.log.Info("github connect enabled (/v1/github/*, /v1/orgs/{id}/github/*) — GITHUB_CONNECT_ENABLED")
}
