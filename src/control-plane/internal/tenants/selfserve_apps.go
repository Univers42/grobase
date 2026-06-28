/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   selfserve_apps.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// appRoutes serves per-account self-serve app creation: a logged-in account turns a name into a
// NEW app-tenant backed by its OWN fresh physical database (the strongest isolation boundary),
// then a scoped key. Each app is a distinct tenant, so a foreign app's key can never resolve it.
type appRoutes struct {
	svc        *Service
	auth       *SelfAuthenticator
	reconciler *provision.Reconciler
	db         *pg.Postgres
	baseDSN    string
}

// SelfServeAppsDeps groups the dependencies MountSelfServeApps wires in. BaseDSN is the control
// plane's own DATABASE_URL; each app's mount DSN is it with the database path swapped.
type SelfServeAppsDeps struct {
	Svc        *Service
	Auth       *SelfAuthenticator
	Reconciler *provision.Reconciler
	DB         *pg.Postgres
	BaseDSN    string
}

// CreateAppRequest is the POST /v1/tenants/me/apps body. Engine is accepted but currently always
// provisioned as postgresql.
type CreateAppRequest struct {
	Name   string `json:"name"`
	Engine string `json:"engine,omitempty"`
}

// MountSelfServeApps registers the self-serve app routes. The caller gates this on
// APPS_SELFSERVE_ENABLED, so OFF ⇒ the routes do not exist (404 = byte-parity).
func MountSelfServeApps(mux *http.ServeMux, d SelfServeAppsDeps) {
	a := &appRoutes{svc: d.Svc, auth: d.Auth, reconciler: d.Reconciler, db: d.DB, baseDSN: d.BaseDSN}
	mux.HandleFunc("POST /v1/tenants/me/apps", a.createApp)
	mux.HandleFunc("GET /v1/tenants/me/apps", a.listApps)
	mux.HandleFunc("DELETE /v1/tenants/me/apps/{appId}", a.deleteApp)
}

// createApp provisions a fresh-DB app for the calling account and returns its key + db id.
func (a *appRoutes) createApp(w http.ResponseWriter, r *http.Request) {
	userID, ok := a.auth.AuthUser(w, r)
	if !ok {
		return
	}
	var req CreateAppRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return
	}
	slug, dbName, err := appIdentity(userID, req.Name)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	if !a.ensureNotTaken(w, r, slug, userID) {
		return
	}
	res, err := a.provisionApp(r.Context(), slug, dbName, req.Name)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "provision_error", err.Error())
		return
	}
	_ = a.svc.StampAccount(r.Context(), slug, userID) // ponytail: orphan-from-listing if stamp fails — app + key still returned
	httpx.WriteJSON(w, http.StatusCreated, appResponse(slug, res))
}

// provisionApp creates the app's fresh database, derives its mount DSN, then reconciles the
// tenant + mount + scoped key in one idempotent call.
func (a *appRoutes) provisionApp(ctx context.Context, slug, dbName, name string) (provision.ReconcileResult, error) {
	if err := a.db.EnsureDatabase(ctx, dbName); err != nil {
		return provision.ReconcileResult{}, err
	}
	dsn, err := appDSN(a.baseDSN, dbName)
	if err != nil {
		return provision.ReconcileResult{}, err
	}
	return a.reconciler.Reconcile(ctx, buildAppSpec(slug, name, dsn))
}

// ensureNotTaken rejects (409) a derived slug that already belongs to a DIFFERENT account, so an
// accidental hash collision can never let one account take over another's app-tenant (its database
// + key). A free slug, or one that is already THIS account's app, is allowed — the latter reconciles
// idempotently. Defense-in-depth behind the 64-bit per-account slug suffix.
func (a *appRoutes) ensureNotTaken(w http.ResponseWriter, r *http.Request, slug, userID string) bool {
	existing, err := a.svc.FindOne(r.Context(), slug)
	if err != nil {
		return true
	}
	if acct, _ := existing.Metadata["account_user_id"].(string); acct != "" && acct != userID {
		httpx.WriteError(w, http.StatusConflict, "conflict", "that app name is unavailable")
		return false
	}
	return true
}
