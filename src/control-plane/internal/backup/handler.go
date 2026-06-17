package backup

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
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
		if !serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
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
			httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
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
	httpx.WriteJSON(w, http.StatusAccepted, map[string]string{
		"backup_id": backupID,
		"status":    "pending",
	})
}

// listBackups returns the tenant's backup rows, newest first.
func (rt *routes) listBackups(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListBackups(r.Context(), r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
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
	httpx.WriteJSON(w, http.StatusAccepted, map[string]string{"status": "restoring"})
}
