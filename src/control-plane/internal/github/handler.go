/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:10 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package github

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handler.go — the /v1/github* (public/relay) + /v1/orgs/{id}/github/* (JWT+RBAC)
// routes. Mounted ONLY when GITHUB_CONNECT_ENABLED is truthy (mount_github.go), so OFF
// ⇒ every route 404 (byte-parity). The device + callback routes are public (the GitHub
// grant / relay HMAC is the authentication, mirroring the sso begin/callback).

type routes struct {
	svc  *Service
	auth *orgs.Authorizer
}

// Deps groups the github route dependencies.
type Deps struct {
	Svc  *Service
	Auth *orgs.Authorizer
}

// Mount registers the github routes onto the shared mux.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{svc: d.Svc, auth: d.Auth}
	mux.HandleFunc("POST /v1/github/callback", rt.callback)
	mux.HandleFunc("GET /v1/github/connect/status", rt.status)
	mux.HandleFunc("POST /v1/github/device/start", rt.deviceStart)
	mux.HandleFunc("POST /v1/github/device/poll", rt.devicePoll)
	mux.HandleFunc("POST /v1/orgs/{orgId}/github/connect/start", rt.connectStart)
	mux.HandleFunc("POST /v1/orgs/{orgId}/github/link", rt.link)
	mux.HandleFunc("POST /v1/orgs/{orgId}/github/sync", rt.sync)
}

// callback is the fly side of the Vercel relay: it verifies the relay HMAC over the
// raw body, then records the installation + marks the nonce ready.
func (rt *routes) callback(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "unreadable body")
		return
	}
	if err := verifyRelay(rt.svc.cfg.RelaySecret, r.Header.Get("X-Github-Relay"), body, time.Now().Unix()); err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "relay signature invalid")
		return
	}
	var req struct {
		InstallationID int64  `json:"installation_id"`
		State          string `json:"state"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	if err := rt.svc.Callback(r.Context(), req.State, req.InstallationID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"recorded": true})
}

// status is the CLI poll for a pending connect.
func (rt *routes) status(w http.ResponseWriter, r *http.Request) {
	nonce := r.URL.Query().Get("nonce")
	if nonce == "" {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "?nonce= is required")
		return
	}
	st, err := rt.svc.Status(r.Context(), nonce)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, st)
}

// deviceStart proxies the GitHub device-code request (no callback).
func (rt *routes) deviceStart(w http.ResponseWriter, r *http.Request) {
	ds, err := rt.svc.DeviceStart(r.Context())
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, ds)
}

// devicePoll exchanges a device code; ErrPending → 200 {authorization_pending}, success
// → 200 {access_token: <session jwt>}.
func (rt *routes) devicePoll(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceCode string `json:"device_code"`
	}
	if !decodeBody(w, r, &req) {
		return
	}
	session, err := rt.svc.DeviceLogin(r.Context(), req.DeviceCode)
	if errors.Is(err, ErrPending) {
		httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "authorization_pending"})
		return
	}
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"access_token": session})
}

// connectStart begins an org-scoped connect (CapOrgUpdate) → a single-use nonce.
func (rt *routes) connectStart(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgUpdate)
	if !ok {
		return
	}
	nonce, installURL, err := rt.svc.StartConnect(r.Context(), orgID, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]string{"nonce": nonce, "install_url": installURL})
}

// link associates a GitHub org login with this vault42 org (CapOrgUpdate).
func (rt *routes) link(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgUpdate)
	if !ok {
		return
	}
	var req struct {
		GithubOrgLogin string `json:"github_org_login"`
	}
	if !decodeBody(w, r, &req) {
		return
	}
	if err := rt.svc.Link(r.Context(), orgID, req.GithubOrgLogin, userID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"linked": true})
}

// sync runs the GitHub→vault42 org sync (CapProjectCreate).
func (rt *routes) sync(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapProjectCreate); !ok {
		return
	}
	summary, err := rt.svc.Sync(r.Context(), orgID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, summary)
}

// decodeBody decodes the JSON request body, writing 400 on failure.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return false
	}
	return true
}

// mapErr maps a github sentinel error to the right HTTP status.
func mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, ErrRelayAuth):
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "relay signature invalid")
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", "already linked")
	case errors.Is(err, ErrUpstream):
		httpx.WriteError(w, http.StatusBadGateway, "upstream_error", "github upstream error")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
