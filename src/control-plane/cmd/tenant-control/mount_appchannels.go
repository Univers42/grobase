/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mount_appchannels.go                               :+:      :+:    :+:   */
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
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/appchannels"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// mountAppChannels mounts the cross-app messaging channel routes (APP_CHANNELS_ENABLED): open /
// accept / list a consented channel between two app-tenants, and mint a realtime JWT carrying the
// protected xapp:<channelId> namespace for each accepted channel. The signing secret is the shared
// JWT_SECRET the realtime plane verifies with, so a minted token authenticates against realtime as
// is. Requires that secret to be set. OFF ⇒ no /v1/app-channels or /v1/realtime/token routes (404
// = byte-parity with the OSS edition).
func (b *bootCtx) mountAppChannels() {
	if !config.EnvBool("APP_CHANNELS_ENABLED") {
		b.log.Info("app channels disabled (APP_CHANNELS_ENABLED off) — routes not mounted")
		return
	}
	if b.jwtSecret == "" {
		b.log.Error("app channels: APP_CHANNELS_ENABLED requires JWT_SECRET/GOTRUE_JWT_SECRET")
		os.Exit(1)
	}
	appchannels.Mount(b.mux, appchannels.Deps{
		Svc:    appchannels.NewService(b.db, b.log),
		Auth:   tenants.NewSelfAuthenticator(b.svc, b.jwtVerifier),
		Secret: b.jwtSecret,
		TTL:    time.Hour,
	})
	b.log.Info("app channels enabled (/v1/app-channels + /v1/realtime/token) — APP_CHANNELS_ENABLED")
}
