/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   appauth.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:44:58 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package github

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// appauth.go — App authentication. The App JWT (RS256, ~9 min) authenticates AS the
// App; it is exchanged for a short installation token (~1h) JUST IN TIME. The
// installation token is returned to the caller, used, and discarded — NEVER persisted
// (no table column holds it). The App private key lives only in memory (Config).

// appJWT mints a short RS256 App JWT signed with the App private key.
func (s *Service) appJWT() (string, error) {
	key, err := jwt.ParseRSAPrivateKeyFromPEM(s.cfg.AppPrivateKey)
	if err != nil {
		return "", ErrConfig
	}
	now := s.now()
	claims := jwt.RegisteredClaims{
		IssuedAt:  jwt.NewNumericDate(now.Add(-30 * time.Second)),
		ExpiresAt: jwt.NewNumericDate(now.Add(9 * time.Minute)),
		Issuer:    s.cfg.AppID,
	}
	return jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(key)
}

// installationToken mints a short-lived installation token for installID just in time.
// The returned token must be used immediately and discarded; it is never stored.
func (s *Service) installationToken(ctx context.Context, installID int64) (string, error) {
	appTok, err := s.appJWT()
	if err != nil {
		return "", err
	}
	var out struct {
		Token string `json:"token"`
	}
	url := fmt.Sprintf("%s/app/installations/%d/access_tokens", s.cfg.APIBase, installID)
	if err := s.ghJSON(ctx, http.MethodPost, url, "Bearer "+appTok, acceptGitHub, nil, &out); err != nil {
		return "", err
	}
	if out.Token == "" {
		return "", ErrUpstream
	}
	return out.Token, nil
}
