/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:14 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package github

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/teams"
)

// Service orchestrates GitHub connect / device-login / org-sync. It holds the App
// config (with the runtime secrets), an HTTP client to GitHub (base URLs injected so
// a gate can point at a mock), and the org + teams services it upserts into. `now`
// is injectable for deterministic tests. No globals.
type Service struct {
	db    *pg.Postgres
	orgs  *orgs.Service
	teams *teams.Service
	cfg   Config
	http  *http.Client
	log   *slog.Logger
	now   func() time.Time
}

// NewService wires the DB pool, the org + teams services, the GitHub config, and a
// logger.
func NewService(db *pg.Postgres, o *orgs.Service, t *teams.Service, cfg Config, log *slog.Logger) *Service {
	return &Service{
		db:    db,
		orgs:  o,
		teams: t,
		cfg:   cfg,
		http:  &http.Client{Timeout: 15 * time.Second},
		log:   log,
		now:   time.Now,
	}
}
