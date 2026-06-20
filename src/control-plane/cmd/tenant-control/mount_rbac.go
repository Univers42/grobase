package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
	"github.com/dlesieur/mini-baas/control-plane/internal/teams"
)

// mountRBACHierarchy mounts the Track-D RBAC hierarchy — teams, project-role grants,
// the effective-permission resolver, and scoped non-escalating tokens
// (RBAC_HIERARCHY_ENABLED). Teams live under an org, so it requires ORG_MODEL_ENABLED
// (the SCIM-precedent dependency guard). OFF ⇒ none of the /v1/orgs/{id}/teams|grants|
// tokens routes exist (404 = byte-parity with today).
func (b *bootCtx) mountRBACHierarchy() {
	if !config.EnvBool("RBAC_HIERARCHY_ENABLED") {
		b.log.Info("RBAC hierarchy disabled (RBAC_HIERARCHY_ENABLED off) — /v1/orgs/{id}/teams|grants|tokens not mounted")
		return
	}
	if !config.EnvBool("ORG_MODEL_ENABLED") {
		b.log.Error("teams: RBAC_HIERARCHY_ENABLED requires ORG_MODEL_ENABLED (teams live under orgs)")
		os.Exit(1)
	}
	if b.jwtVerifier == nil {
		b.log.Error("teams: RBAC_HIERARCHY_ENABLED requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		os.Exit(1)
	}
	osvc := orgs.NewService(b.db, b.log)
	auth := orgs.NewAuthorizer(osvc, b.jwtVerifier)
	tsvc := teams.NewService(b.db, osvc, audit.NewService(b.db), b.log)
	teams.Mount(b.mux, teams.Deps{Svc: tsvc, Auth: auth})
	b.log.Info("RBAC hierarchy enabled (/v1/orgs/{id}/teams|grants|tokens) — RBAC_HIERARCHY_ENABLED")
}
