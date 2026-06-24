/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   escrow.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:27 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package loginotp

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/golang-jwt/jwt/v5"
)

// escrow.go — multi-device keystore escrow. A passphrase-wrapped keystore blob is
// stored per email and fetched on a second device after an OTP proof confirms mailbox
// control; the blob is opaque (server never decrypts) and the passphrase unlocks it
// locally — zero-knowledge end to end. PUT stores; POST /fetch returns (proof in the
// body, not the URL).

// verifyProof checks an OTP proof JWT (HS256, our own secret): valid signature + exp,
// `aud==otp-proof`, and `otp==lower(email)`.
func (s *Service) verifyProof(proof, email string) bool {
	tok, err := jwt.Parse(proof, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrTokenUnverifiable
		}
		return s.jwtSecret, nil
	})
	if err != nil || !tok.Valid {
		return false
	}
	claims, ok := tok.Claims.(jwt.MapClaims)
	if !ok {
		return false
	}
	aud, _ := claims["aud"].(string)
	otp, _ := claims["otp"].(string)
	return aud == "otp-proof" && otp == strings.ToLower(email)
}

// putEscrowRow upserts the keystore blob for email.
func (s *Service) putEscrowRow(ctx context.Context, email, blob string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.login_escrow (email, blob, updated_at) VALUES (lower($1), $2, $3)
		ON CONFLICT (email) DO UPDATE SET blob = EXCLUDED.blob,
		  version = public.login_escrow.version + 1, updated_at = EXCLUDED.updated_at`,
		email, blob, s.now().Unix())
}

// getEscrowRow reads the keystore blob for email (ok=false when absent).
func (s *Service) getEscrowRow(ctx context.Context, email string) (string, bool) {
	rows, err := s.db.AdminQuery(ctx, `SELECT blob FROM public.login_escrow WHERE email=lower($1)`, email)
	if err != nil {
		return "", false
	}
	defer rows.Close()
	if !rows.Next() {
		return "", false
	}
	var blob string
	if err := rows.Scan(&blob); err != nil {
		return "", false
	}
	return blob, true
}

// escrowPut stores a passphrase-wrapped keystore blob after verifying the OTP proof.
func (rt *routes) escrowPut(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
		Proof string `json:"proof"`
		Blob  string `json:"blob"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Email == "" || req.Blob == "" {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "email + blob required")
		return
	}
	if !rt.svc.verifyProof(req.Proof, req.Email) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "valid OTP proof required")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := rt.svc.putEscrowRow(ctx, req.Email, req.Blob); err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "could not store escrow")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"stored": true})
}

// escrowFetch returns the keystore blob after verifying the OTP proof (proof in the
// body, never the URL).
func (rt *routes) escrowFetch(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
		Proof string `json:"proof"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Email == "" {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "email required")
		return
	}
	if !rt.svc.verifyProof(req.Proof, req.Email) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "valid OTP proof required")
		return
	}
	blob, ok := rt.svc.getEscrowRow(r.Context(), req.Email)
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "no escrow for this account")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"blob": blob})
}
