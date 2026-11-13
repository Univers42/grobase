/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   helpers.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:41 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package gdprsvc

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

/* ─────── helpers ─────── */

func (s *Service) fail(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, errConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", "conflict")
	case errors.Is(err, errCompleted):
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "Request already completed")
	default:
		s.log.Error("gdpr store error", "err", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "unexpected error")
	}
	return true
}

func requireUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-User-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "missing verified identity")
	return "", false
}

func (s *Service) requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	_, ok := s.requireAdminUser(w, r)
	return ok
}

// requireAdminUser admits only an internal service caller. The X-Baas-Role header is
// set by Kong for public traffic but forgeable by anything on the compose network, so
// on its own it opened the GDPR processing route that fires the erasure webhook and
// anonymises audit_log (#85); the service token is checked first.
func (s *Service) requireAdminUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !serviceauth.VerifyServiceRequest(r, s.serviceToken) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return "", false
	}
	userID, ok := requireUser(w, r)
	if !ok {
		return "", false
	}
	if r.Header.Get("X-Baas-Role") != "service_role" {
		httpx.WriteError(w, http.StatusForbidden, "forbidden", "requires one of: service_role")
		return "", false
	}
	return userID, true
}

func validStatus(s string) bool {
	return s == "in_progress" || s == "completed" || s == "rejected"
}
