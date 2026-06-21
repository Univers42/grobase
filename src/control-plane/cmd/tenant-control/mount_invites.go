/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mount_invites.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/invites"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// mountInvites mounts the generalized team/group invite routes + the registered-accept path
// (INVITES_ENABLED). Invites target the RBAC hierarchy, so it requires RBAC_HIERARCHY_ENABLED
// + ORG_MODEL_ENABLED. OFF ⇒ no /v1/orgs/{id}/teams/{id}/invites, /v1/groups/{id}/invites,
// or /v1/invites/* routes (404 = byte-parity). Org invites keep their own system (orgs/043).
func (b *bootCtx) mountInvites() {
	if !config.EnvBool("INVITES_ENABLED") {
		b.log.Info("invites disabled (INVITES_ENABLED off) — generalized invite routes not mounted")
		return
	}
	if !config.EnvBool("RBAC_HIERARCHY_ENABLED") || !config.EnvBool("ORG_MODEL_ENABLED") {
		b.log.Error("invites: INVITES_ENABLED requires RBAC_HIERARCHY_ENABLED + ORG_MODEL_ENABLED")
		os.Exit(1)
	}
	if b.jwtVerifier == nil {
		b.log.Error("invites: INVITES_ENABLED requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		os.Exit(1)
	}
	auth := orgs.NewAuthorizer(orgs.NewService(b.db, b.log), b.jwtVerifier)
	invites.Mount(b.mux, invites.Deps{Svc: invites.NewService(b.db, b.log), Auth: auth})
	b.log.Info("invites enabled (team/group invites + /v1/invites/accept) — INVITES_ENABLED")
}
