/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mount_appsselfserve.go                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// mountAppsSelfServe mounts strict self-serve app creation (APPS_SELFSERVE_ENABLED): a logged-in
// account POSTs a name and gets back a NEW app-tenant on its OWN fresh physical database + a scoped
// key. Requires a JWT verifier (app creation is account-driven) and the provisioning reconciler.
// OFF ⇒ no /v1/tenants/me/apps routes (404 = byte-parity with the OSS edition).
func (b *bootCtx) mountAppsSelfServe() {
	if !config.EnvBool("APPS_SELFSERVE_ENABLED") {
		b.log.Info("self-serve apps disabled (APPS_SELFSERVE_ENABLED off) — routes not mounted")
		return
	}
	if b.jwtVerifier == nil {
		b.log.Error("self-serve apps: APPS_SELFSERVE_ENABLED requires a JWT verifier (GOTRUE_JWT_SECRET)")
		os.Exit(1)
	}
	if b.reconciler == nil {
		b.log.Error("self-serve apps: APPS_SELFSERVE_ENABLED requires the provisioning reconciler")
		os.Exit(1)
	}
	tenants.MountSelfServeApps(b.mux, tenants.SelfServeAppsDeps{
		Svc:        b.svc,
		Auth:       tenants.NewSelfAuthenticator(b.svc, b.jwtVerifier),
		Reconciler: b.reconciler,
		DB:         b.db,
		BaseDSN:    b.cfg.DatabaseURL,
	})
	b.log.Info("self-serve apps enabled (POST/GET/DELETE /v1/tenants/me/apps) — APPS_SELFSERVE_ENABLED")
}
