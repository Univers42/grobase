/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mount_pubkeys.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 07:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 07:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
	"github.com/dlesieur/mini-baas/control-plane/internal/pubkeys"
)

// mountPubkeys mounts the member X25519 pubkey registry + the grant-fulfilment seam
// (USER_PUBKEYS_ENABLED) — the bridge to the vault42 zero-knowledge crypto plane. It needs
// orgs (membership) + RBAC hierarchy (grants), so it requires RBAC_HIERARCHY_ENABLED +
// ORG_MODEL_ENABLED. OFF ⇒ no /v1/orgs/{id}/pubkey, /users/{id}/pubkey, /grants/{id}/wraps,
// or /grants/{id}/fulfilled routes (404 = byte-parity).
func (b *bootCtx) mountPubkeys() {
	if !config.EnvBool("USER_PUBKEYS_ENABLED") {
		b.log.Info("user pubkeys disabled (USER_PUBKEYS_ENABLED off) — pubkey registry not mounted")
		return
	}
	if !config.EnvBool("RBAC_HIERARCHY_ENABLED") || !config.EnvBool("ORG_MODEL_ENABLED") {
		b.log.Error("pubkeys: USER_PUBKEYS_ENABLED requires RBAC_HIERARCHY_ENABLED + ORG_MODEL_ENABLED")
		os.Exit(1)
	}
	if b.jwtVerifier == nil {
		b.log.Error("pubkeys: USER_PUBKEYS_ENABLED requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		os.Exit(1)
	}
	auth := orgs.NewAuthorizer(orgs.NewService(b.db, b.log), b.jwtVerifier)
	pubkeys.Mount(b.mux, pubkeys.Deps{Svc: pubkeys.NewService(b.db, b.log), Auth: auth})
	b.log.Info("user pubkeys enabled (registry + grant-fulfilment seam) — USER_PUBKEYS_ENABLED")
}
