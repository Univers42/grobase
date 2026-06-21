/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   client.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:01 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:03 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package github

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
)

// client.go — the GitHub REST + OAuth-device client. Base URLs are injected (Config)
// so a gate can point at a mock. Every read uses a freshly-minted, in-memory token.

const acceptGitHub = "application/vnd.github+json"

// ghJSON performs one JSON request to GitHub, decoding a 2xx body into out.
func (s *Service) ghJSON(ctx context.Context, method, endpoint, auth, accept string, reqBody, out any) error {
	var rdr io.Reader
	if reqBody != nil {
		b, _ := json.Marshal(reqBody)
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, rdr)
	if err != nil {
		return ErrUpstream
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	req.Header.Set("Accept", accept)
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := s.http.Do(req)
	if err != nil {
		return ErrUpstream
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return ErrUpstream
	}
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return ErrUpstream
	}
	return nil
}

// getInstallation reads an installation's identity (org login/id + granted scopes).
func (s *Service) getInstallation(ctx context.Context, installID int64) (Installation, error) {
	appTok, err := s.appJWT()
	if err != nil {
		return Installation{}, err
	}
	var raw struct {
		Account struct {
			Login string `json:"login"`
			ID    int64  `json:"id"`
		} `json:"account"`
		AppSlug     string         `json:"app_slug"`
		Permissions map[string]any `json:"permissions"`
	}
	url := fmt.Sprintf("%s/app/installations/%d", s.cfg.APIBase, installID)
	if err := s.ghJSON(ctx, http.MethodGet, url, "Bearer "+appTok, acceptGitHub, nil, &raw); err != nil {
		return Installation{}, err
	}
	return Installation{
		InstallationID: installID, OrgLogin: raw.Account.Login, OrgID: raw.Account.ID,
		AppSlug: raw.AppSlug, Permissions: raw.Permissions,
	}, nil
}

// ghUser is a GitHub user (login + numeric id).
type ghUser struct {
	Login string `json:"login"`
	ID    int64  `json:"id"`
}

// ghTeam is a GitHub team (slug + name).
type ghTeam struct {
	Slug string `json:"slug"`
	Name string `json:"name"`
}

// listOrgMembers reads the org's members using an installation token.
func (s *Service) listOrgMembers(ctx context.Context, instTok, org string) ([]ghUser, error) {
	var out []ghUser
	url := fmt.Sprintf("%s/orgs/%s/members", s.cfg.APIBase, org)
	return out, s.ghJSON(ctx, http.MethodGet, url, "Bearer "+instTok, acceptGitHub, nil, &out)
}

// listOrgTeams reads the org's teams using an installation token.
func (s *Service) listOrgTeams(ctx context.Context, instTok, org string) ([]ghTeam, error) {
	var out []ghTeam
	url := fmt.Sprintf("%s/orgs/%s/teams", s.cfg.APIBase, org)
	return out, s.ghJSON(ctx, http.MethodGet, url, "Bearer "+instTok, acceptGitHub, nil, &out)
}

// listTeamMembers reads a team's members using an installation token.
func (s *Service) listTeamMembers(ctx context.Context, instTok, org, teamSlug string) ([]ghUser, error) {
	var out []ghUser
	url := fmt.Sprintf("%s/orgs/%s/teams/%s/members", s.cfg.APIBase, org, teamSlug)
	return out, s.ghJSON(ctx, http.MethodGet, url, "Bearer "+instTok, acceptGitHub, nil, &out)
}

// deviceStart proxies GitHub's device-code request (no callback flow).
func (s *Service) deviceStart(ctx context.Context) (DeviceStart, error) {
	var out DeviceStart
	endpoint := fmt.Sprintf("%s/login/device/code?client_id=%s&scope=read:user",
		s.cfg.OAuthBase, url.QueryEscape(s.cfg.ClientID))
	return out, s.ghJSON(ctx, http.MethodPost, endpoint, "", "application/json", nil, &out)
}

// devicePoll exchanges a device code for a user token, returning the GitHub user
// once approved, ErrPending while waiting. The GitHub token is used once + discarded.
func (s *Service) devicePoll(ctx context.Context, deviceCode string) (ghUser, error) {
	var tok struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	body := map[string]string{
		"client_id":   s.cfg.ClientID,
		"device_code": deviceCode,
		"grant_type":  "urn:ietf:params:oauth:grant-type:device_code",
	}
	endpoint := s.cfg.OAuthBase + "/login/oauth/access_token"
	if err := s.ghJSON(ctx, http.MethodPost, endpoint, "", "application/json", body, &tok); err != nil {
		return ghUser{}, err
	}
	if tok.AccessToken == "" {
		return ghUser{}, ErrPending
	}
	var user ghUser
	if err := s.ghJSON(ctx, http.MethodGet, s.cfg.APIBase+"/user", "Bearer "+tok.AccessToken, acceptGitHub, nil, &user); err != nil {
		return ghUser{}, err
	}
	return user, nil
}
