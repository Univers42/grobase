/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:28 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package loginotp

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handler.go — the public /v1/auth/otp/* routes (pre-login, so no JWT). Mounted ONLY
// when EMAIL_OTP_ENABLED is truthy.

type routes struct{ svc *Service }

// Mount registers the OTP request/verify routes.
func Mount(mux *http.ServeMux, svc *Service) {
	rt := &routes{svc: svc}
	mux.HandleFunc("POST /v1/auth/otp/request", rt.request)
	mux.HandleFunc("POST /v1/auth/otp/verify", rt.verify)
	mux.HandleFunc("PUT /v1/auth/escrow", rt.escrowPut)
	mux.HandleFunc("POST /v1/auth/escrow/fetch", rt.escrowFetch)
}

// request mails a code. It answers 200 {"sent":true} for any address whose mail went
// out (no email enumeration: registered or not looks the same) and 502
// {"error":"send_failed"} when the SMTP send fails.
func (rt *routes) request(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Email) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "email is required")
		return
	}
	if err := rt.svc.Request(r.Context(), req.Email); err != nil {
		if errors.Is(err, ErrSendFailed) {
			httpx.WriteError(w, http.StatusBadGateway, "send_failed", "could not send the code")
			return
		}
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "could not issue a code")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"sent": true})
}

// verify checks a code. Success is 200 {"verified":true,"proof":"<jwt>"}. The proof
// is a compact JWT signed HS256 with GOTRUE_JWT_SECRET (the same key GoTrue signs
// with, so anything holding that secret can verify it), claims
// {otp:<lowercased email>, aud:"otp-proof", iat, exp = iat+5min}. It carries no
// "iss" or "sub". A verifier must check the signature, aud, exp, and that "otp"
// equals the email it is acting for: the proof is bound to an email, not to a
// session, and is not single-use after minting. Failures: 401 invalid_code
// (wrong or no live code), 410 expired, 429 too_many_attempts.
func (rt *routes) verify(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	proof, err := rt.svc.Verify(r.Context(), req.Email, req.Code)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"verified": true, "proof": proof})
}

// mapErr maps an OTP sentinel error to the right HTTP status.
func mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrExpired):
		httpx.WriteError(w, http.StatusGone, "expired", "code expired — request a new one")
	case errors.Is(err, ErrLocked):
		httpx.WriteError(w, http.StatusTooManyRequests, "too_many_attempts", "too many attempts — request a new code")
	case errors.Is(err, ErrNoCode), errors.Is(err, ErrInvalid):
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_code", "invalid code")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
