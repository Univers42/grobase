/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mount_groups.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/environments"
	"github.com/dlesieur/mini-baas/control-plane/internal/groups"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// mountEnvironments mounts the per-project environment routes (ENVIRONMENTS_ENABLED). An
// environment lives under a project(=tenant) inside the RBAC hierarchy, so it requires
// RBAC_HIERARCHY_ENABLED + ORG_MODEL_ENABLED. OFF ⇒ no /v1/projects/{id}/environments routes
// (404 = byte-parity).
func (b *bootCtx) mountEnvironments() {
	if !config.EnvBool("ENVIRONMENTS_ENABLED") {
		b.log.Info("environments disabled (ENVIRONMENTS_ENABLED off) — /v1/projects/{id}/environments not mounted")
		return
	}
	if !config.EnvBool("RBAC_HIERARCHY_ENABLED") || !config.EnvBool("ORG_MODEL_ENABLED") {
		b.log.Error("environments: ENVIRONMENTS_ENABLED requires RBAC_HIERARCHY_ENABLED + ORG_MODEL_ENABLED")
		os.Exit(1)
	}
	if b.jwtVerifier == nil {
		b.log.Error("environments: ENVIRONMENTS_ENABLED requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		os.Exit(1)
	}
	auth := orgs.NewAuthorizer(orgs.NewService(b.db, b.log), b.jwtVerifier)
	environments.Mount(b.mux, environments.Deps{Svc: environments.NewService(b.db, b.log), Auth: auth})
	b.log.Info("environments enabled (/v1/projects/{id}/environments) — ENVIRONMENTS_ENABLED")
}

// mountGroups mounts the project-scoped group routes (GROUPS_ENABLED), same dependency chain
// as environments. OFF ⇒ no /v1/projects/{id}/groups or /v1/groups/{id}/members routes.
func (b *bootCtx) mountGroups() {
	if !config.EnvBool("GROUPS_ENABLED") {
		b.log.Info("groups disabled (GROUPS_ENABLED off) — /v1/projects/{id}/groups not mounted")
		return
	}
	if !config.EnvBool("RBAC_HIERARCHY_ENABLED") || !config.EnvBool("ORG_MODEL_ENABLED") {
		b.log.Error("groups: GROUPS_ENABLED requires RBAC_HIERARCHY_ENABLED + ORG_MODEL_ENABLED")
		os.Exit(1)
	}
	if b.jwtVerifier == nil {
		b.log.Error("groups: GROUPS_ENABLED requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		os.Exit(1)
	}
	auth := orgs.NewAuthorizer(orgs.NewService(b.db, b.log), b.jwtVerifier)
	groups.Mount(b.mux, groups.Deps{Svc: groups.NewService(b.db, b.log), Auth: auth})
	b.log.Info("groups enabled (/v1/projects/{id}/groups, /v1/groups/{id}/members) — GROUPS_ENABLED")
}
