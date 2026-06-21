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

func requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	_, ok := requireAdminUser(w, r)
	return ok
}

func requireAdminUser(w http.ResponseWriter, r *http.Request) (string, bool) {
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
