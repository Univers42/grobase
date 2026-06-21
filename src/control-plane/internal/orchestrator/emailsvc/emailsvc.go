/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   emailsvc.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:59 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package emailsvc is the Go port of the Node email-service (R2 consolidation).
//
// It exposes POST /send, builds an RFC 5322 message from {to,subject,html,text}
// and hands it to SMTP — a faithful port of the NestJS MailController +
// MailService (nodemailer), so an internal caller (newsletter, gdpr, …) cannot
// tell which runtime served it. Running it inside the orchestrator binary
// instead of a ~50 MiB Node runtime is the R2 footprint win.
//
// The real internal caller posts /send with only Content-Type (no identity
// envelope) and relies on docker-network isolation, so — like the Node
// controller behind the cluster boundary and like logsvc — the route is mounted
// plainly; the host middleware owns transport-level auth.
package emailsvc

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
)

// Service holds the SMTP transport config + the send seam (overridable in tests).
type Service struct {
	log    *slog.Logger
	host   string
	port   int
	secure bool
	user   string
	pass   string
	from   string

	// send is the transport seam. Production uses smtpSend; tests inject a
	// capturing func so the message shape is asserted without a live server.
	send func(m *message) error
}

// New builds the service from env (parity with the Node/compose defaults:
// SMTP_HOST=mailpit, SMTP_PORT=1025, SMTP_SECURE=false, no auth).
func New(log *slog.Logger) *Service {
	s := &Service{
		log:    log,
		host:   config.EnvStr("SMTP_HOST", "mailpit"),
		port:   config.EnvInt("SMTP_PORT", 1025),
		secure: config.EnvStr("SMTP_SECURE", "false") == "true",
		user:   config.EnvStr("SMTP_USER", ""),
		pass:   config.EnvStr("SMTP_PASS", ""),
		from:   config.EnvStr("EMAIL_FROM", "noreply@mini-baas.local"),
	}
	s.send = s.smtpSend
	return s
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "email" }

// Mount registers the HTTP surface. /health/* and /metrics are owned by the
// shared router, so email only adds its one route.
func (s *Service) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /send", s.handleSend)
}

// Run has no background loop (sends are synchronous); it just parks until the
// orchestrator shuts down so the goroutine exits cleanly.
func (s *Service) Run(ctx context.Context) { <-ctx.Done() }
