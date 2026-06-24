/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_user.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:50:34 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package sessionsvc

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

/* ─────── User endpoints ─────── */

type createBody struct {
	Token      string `json:"token"`
	DeviceInfo string `json:"deviceInfo"`
	IPAddress  string `json:"ipAddress"`
}

func (s *Service) create(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var b createBody
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || strings.TrimSpace(b.Token) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "token is required")
		return
	}
	sess, err := s.store.create(r.Context(), userID, b.Token, b.DeviceInfo, b.IPAddress)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, sess)
}

func (s *Service) mine(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	out, err := s.store.userSessions(r.Context(), userID, bearer(r))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (s *Service) validate(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Token string `json:"token"`
	}
	_ = json.NewDecoder(r.Body).Decode(&b)
	valid, sess, err := s.store.validate(r.Context(), b.Token)
	if s.fail(w, err) {
		return
	}
	resp := map[string]any{"valid": valid}
	if sess != nil {
		resp["session"] = sess
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}

func (s *Service) extend(w http.ResponseWriter, r *http.Request) {
	if _, ok := requireUser(w, r); !ok {
		return
	}
	var b struct {
		Days string `json:"days"`
	}
	_ = json.NewDecoder(r.Body).Decode(&b)
	days := 0
	if b.Days != "" {
		days, _ = strconv.Atoi(b.Days)
	}
	sess, err := s.store.extend(r.Context(), bearer(r), days)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"id": sess.ID, "expires_at": sess.ExpiresAt})
}
