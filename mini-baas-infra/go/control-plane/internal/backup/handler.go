package backup

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// Mount registers the THREE admin backup/restore routes onto the shared mux
// (Track-B B6). All three require a control-plane service token (mirroring
// tenants.routes.requireServiceToken at handler.go:70 — the verified admin auth
// shape), and read the tenant id from the path via r.PathValue("id") (Go 1.22
// net/http mux, same as metering/webhooks/functriggers).
//
//	POST /v1/tenants/{id}/backup               body {mount?} -> 202 {backup_id, status}
//	GET  /v1/tenants/{id}/backups              -> 200 [{id, mount, isolation, ...}]
//	POST /v1/tenants/{id}/restore/{backupId}   -> 202 {status:"restoring"}
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when TENANT_BACKUP_ENABLED is
// truthy. When the flag is OFF (the default) Mount is never called, so none of
// these routes are registered on the mux and a request 404s — byte-identical to
// today. This is the exact discipline of tenants.MountSelfServe /
// metering.Mount: additive, opt-in, zero baseline change.
//
// Per-tenant backup/restore is MVP-scoped to the two CLEAN isolation models
// (schema_per_tenant, db_per_tenant); shared_rls and tenant_owned are rejected
// 400 "isolation not supported for backup/restore (deferred)" — the service
// layer (guardIsolation) raises ErrIsolationDeferred, mapped here.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}

	mux.HandleFunc("POST /v1/tenants/{id}/backup", rt.requireServiceToken(rt.createBackup))
	mux.HandleFunc("GET /v1/tenants/{id}/backups", rt.requireServiceToken(rt.listBackups))
	mux.HandleFunc("POST /v1/tenants/{id}/restore/{backupId}", rt.requireServiceToken(rt.restore))
}

type routes struct {
	svc          *Service
	serviceToken string
}

const msgInvalidJSON = "invalid JSON"

// requireServiceToken gates a handler behind the control-plane service token,
// byte-identical to tenants.routes.requireServiceToken — admin backup/restore is
// a privileged control-plane operation, never reachable by a tenant credential.
func (rt *routes) requireServiceToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !shared.VerifyServiceRequest(r, rt.serviceToken) {
			shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

// createBackupRequest is the optional POST /v1/tenants/{id}/backup body. An empty
// body (or omitted mount) backs up the whole tenant; a named mount narrows it.
type createBackupRequest struct {
	Mount string `json:"mount"`
}

// createBackup kicks off a logical backup of one tenant's data and records a row
// in public.tenant_backups. Returns 202 with the new backup id — the extract is
// synchronous in the service (status reaches 'completed'/'failed' before return),
// but the API surface is async-shaped (202 + status) so a future queued backend
// is a drop-in. A deferred isolation model is rejected 400 BEFORE any work.
func (rt *routes) createBackup(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req createBackupRequest
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
	}
	backupID, err := rt.svc.CreateBackup(r.Context(), id, strings.TrimSpace(req.Mount))
	if rt.handleBackupErr(w, err) {
		return
	}
	// CreateBackup returns the ledger id (and reaches a terminal status before
	// returning); the API surface stays async-shaped (202 + status:"pending") so a
	// future queued backend is a drop-in without a contract change.
	shared.WriteJSON(w, http.StatusAccepted, map[string]string{
		"backup_id": backupID,
		"status":    "pending",
	})
}

// listBackups returns the tenant's backup rows, newest first.
func (rt *routes) listBackups(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListBackups(r.Context(), r.PathValue("id"))
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// restore replays a backup into the tenant's OWN namespace. The service validates
// (load-bearing) that the backup row's tenant_id matches {id} BEFORE any DDL: a
// mismatch (or unknown backup) yields ErrNotOwned -> 404, so a restore of A can
// never touch B even if a B caller guessed A's backup id. A deferred isolation
// model is rejected 400.
func (rt *routes) restore(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	backupID := r.PathValue("backupId")
	if err := rt.svc.Restore(r.Context(), id, backupID); rt.handleBackupErr(w, err) {
		return
	}
	// Restore returns only error (it flips the ledger status itself); the handler
	// reports the async-shaped acknowledgement the contract specifies.
	shared.WriteJSON(w, http.StatusAccepted, map[string]string{"status": "restoring"})
}

// handleBackupErr maps the backup service's sentinel errors to HTTP status codes,
// mirroring tenants.routes.handleLookup. Returns true when an error was written.
//
//	ErrIsolationDeferred -> 400 (shared_rls / tenant_owned are out of MVP scope)
//	ErrNotOwned          -> 404 (backup.tenant_id != request tenant; load-bearing —
//	                            the module slice returns this for an unknown backup
//	                            too, since the lookup binds (id, tenant_id))
//	anything else        -> 500
func (rt *routes) handleBackupErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrIsolationDeferred):
		shared.WriteError(w, http.StatusBadRequest, "isolation_unsupported",
			"isolation not supported for backup/restore (deferred)")
	case errors.Is(err, ErrNotOwned):
		// 404 (not 403) so the existence of another tenant's backup is not even
		// confirmed to a probing caller — same opacity as a missing row. The
		// module-slice Restore returns ErrNotOwned for BOTH a wrong-tenant backup
		// and an unknown id (the SELECT binds id AND tenant_id), so this one arm
		// covers the whole load-bearing caller==owner contract.
		shared.WriteError(w, http.StatusNotFound, "not_found", "backup not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}

// keyResolver is the seam the read-only self-serve route uses to resolve a tenant
// API key to its owning tenant. *tenants.Service satisfies it (its exported
// VerifyKey returns tenants.VerifyKeyResponse{Valid, TenantID, ...}); this
// package depends on tenants only at this boundary, and a fake satisfies the seam
// in unit tests with no live key store.
//
// JWT-bearer self-serve is intentionally NOT wired here: tenants.Service exposes
// VerifyKey (exported) but its user->tenant resolver (findForUser) is unexported,
// and B6 does not own the tenants package. The PRIMARY self-serve case — a tenant
// listing its own backups programmatically — is an API-key call, which this seam
// covers fully. JWT-bearer backup listing is a documented deferral (B6b): a user
// can still list backups via an admin token or an issued API key today.
type keyResolver interface {
	VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error)
}

// MountSelfServe registers the READ-ONLY self-serve route
//
//	GET /v1/tenants/me/backups
//
// onto the shared mux. A caller authenticated AS a tenant via an API key lists ITS
// OWN backups. There is NO path id, so cross-tenant access is impossible by
// construction — the tenant is resolved from the credential and bound into an
// RLS-scoped SELECT (defense-in-depth atop the RLS policy on tenant_backups).
//
// SECOND FLAG: main.go calls MountSelfServe ONLY when BOTH TENANT_BACKUP_ENABLED
// and TENANT_BACKUP_SELFSERVE_ENABLED are truthy (the latter narrows the
// self-serve surface exactly as BILLING_ENABLED narrows tenants.MountSelfServe).
// When either is OFF this route is not registered -> 404 = parity.
//
// keys is the credential resolver (the tenants Service); it must be non-nil when
// this route is mounted. The backup Service supplies the RLS-scoped ListBackups.
func MountSelfServe(mux *http.ServeMux, svc *Service, keys keyResolver) {
	ss := &selfRoutes{svc: svc, keys: keys}
	// Static "me" out-ranks the {id} wildcard (net/http most-specific-pattern
	// precedence), so this never collides with the admin GET .../{id}/backups.
	mux.HandleFunc("GET /v1/tenants/me/backups", ss.listMine)
}

type selfRoutes struct {
	svc  *Service
	keys keyResolver
}

// listMine returns the caller's OWN backups. The tenant id is resolved from the
// credential (never the request path), then passed to the same RLS-scoped
// ListBackups the admin route uses — defense-in-depth atop the RLS policy on
// public.tenant_backups (migration 042).
func (ss *selfRoutes) listMine(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	out, err := ss.svc.ListBackups(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// selfAuth resolves the caller's OWN tenant id from its API key (X-API-Key or
// `Authorization: Bearer mbk_...`), mirroring tenants.selfServe.selfAuth's
// API-key arm (selfserve.go:70). On any failure it writes a 401 and returns
// ok=false. The returned id is the canonical tenant slug ListBackups keys on — a
// caller can therefore only ever list its OWN tenant's backups.
func (ss *selfRoutes) selfAuth(w http.ResponseWriter, r *http.Request) (tenantID string, ok bool) {
	raw := apiKeyFromRequest(r)
	if raw == "" {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"X-API-Key or Authorization: Bearer <api-key> required")
		return "", false
	}
	out, err := ss.keys.VerifyKey(r.Context(), raw)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", false
	}
	if !out.Valid {
		shared.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
		return "", false
	}
	return out.TenantID, true
}

// apiKeyFromRequest extracts a tenant API key from X-API-Key or from an
// `Authorization: Bearer mbk_...` header (the project key prefix), mirroring
// tenants.apiKeyFromRequest. A JWT Bearer (no mbk_ prefix) is left for the JWT
// path, so the two credential types never collide on the same header.
func apiKeyFromRequest(r *http.Request) string {
	if k := strings.TrimSpace(r.Header.Get("X-API-Key")); k != "" {
		return k
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if rest, ok := cutBearer(auth); ok && strings.HasPrefix(rest, "mbk_") {
		return rest
	}
	return ""
}

// cutBearer strips a case-insensitive "Bearer " prefix, returning the remainder
// and whether the prefix was present (mirrors tenants.cutBearer).
func cutBearer(auth string) (string, bool) {
	const p = "bearer "
	if len(auth) >= len(p) && strings.EqualFold(auth[:len(p)], p) {
		return strings.TrimSpace(auth[len(p):]), true
	}
	return "", false
}
