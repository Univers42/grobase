// Package gdprsvc is the Go port of the Node gdpr-service (R2 consolidation).
//
// It ports all three NestJS modules: consent (CRUD over gdpr.user_consent),
// deletion-requests (right-to-be-forgotten lifecycle + admin processing), and
// export (GDPR data portability). Domain-specific data export/erasure is
// delegated to consuming-app webhooks (GDPR_EXPORT_WEBHOOK_URL /
// GDPR_DELETION_WEBHOOK_URL) via seams that are byte-faithful to the Node fetch
// calls and fakeable in tests. Running it inside the orchestrator binary instead
// of a ~50 MiB Node runtime is the R2 footprint win.
//
// All routes require a verified user (X-Baas-User-Id); the admin deletion routes
// additionally require role service_role (parity with the TS RolesGuard).
package gdprsvc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// repo is the gdpr persistence seam (satisfied by *store; faked in tests).
type repo interface {
	bootstrap(ctx context.Context) error
	userConsents(ctx context.Context, userID string) ([]Consent, error)
	userConsent(ctx context.Context, userID, ctype string) (*Consent, error)
	setConsent(ctx context.Context, userID, ctype string, consented bool) (*Consent, error)
	updateConsent(ctx context.Context, userID, ctype string, consented bool) (*Consent, error)
	withdrawNonEssential(ctx context.Context, userID string) (int, error)
	pendingExists(ctx context.Context, userID string) (bool, error)
	createDeletion(ctx context.Context, userID string, reason *string) (*DeletionRequest, error)
	myRequest(ctx context.Context, userID string) (*DeletionRequest, error)
	cancelRequest(ctx context.Context, userID string) (*DeletionRequest, error)
	allRequests(ctx context.Context, status string) ([]DeletionRequest, error)
	getRequest(ctx context.Context, id string) (*DeletionRequest, error)
	updateRequest(ctx context.Context, id, status, adminID string, note *string) (*DeletionRequest, error)
}

// exportFn fetches an app's domain data for a user (GDPR_EXPORT_WEBHOOK_URL).
type exportFn func(ctx context.Context, userID string) map[string]any

// deletionFn notifies the app to erase a user's data (GDPR_DELETION_WEBHOOK_URL).
type deletionFn func(ctx context.Context, userID string)

// Service is the gdpr sub-service.
type Service struct {
	log         *slog.Logger
	store       repo
	doExport    exportFn
	doDeletion  deletionFn
}

// New builds the service from env, wiring the webhook seams to their default
// HTTP implementations.
func New(log *slog.Logger, pg *shared.Postgres) *Service {
	client := &http.Client{Timeout: 10 * time.Second}
	return &Service{
		log:        log,
		store:      &store{pg: pg},
		doExport:   httpExport(client, os.Getenv("GDPR_EXPORT_WEBHOOK_URL"), log),
		doDeletion: httpDeletion(client, os.Getenv("GDPR_DELETION_WEBHOOK_URL"), log),
	}
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "gdpr" }

// Init ensures the gdpr tables exist (parity with the two onModuleInit hooks).
func (s *Service) Init(ctx context.Context) error {
	if err := s.store.bootstrap(ctx); err != nil {
		return err
	}
	s.log.Info("gdpr tables ensured")
	return nil
}

// Mount registers the HTTP surface.
func (s *Service) Mount(mux *http.ServeMux) {
	// consent
	mux.HandleFunc("GET /consents", s.listConsents)
	mux.HandleFunc("POST /consents", s.setConsent)
	mux.HandleFunc("DELETE /consents/non-essential", s.withdrawNonEssential)
	mux.HandleFunc("GET /consents/{type}", s.getConsent)
	mux.HandleFunc("PUT /consents/{type}", s.updateConsent)
	// export
	mux.HandleFunc("GET /export", s.export)
	// deletion
	mux.HandleFunc("POST /deletion-requests", s.createDeletion)
	mux.HandleFunc("GET /deletion-requests/mine", s.myDeletion)
	mux.HandleFunc("DELETE /deletion-requests/mine", s.cancelDeletion)
	mux.HandleFunc("GET /deletion-requests/admin", s.adminListDeletions)
	mux.HandleFunc("POST /deletion-requests/admin/{id}/process", s.adminProcessDeletion)
}

// Run has no background loop; it parks until shutdown.
func (s *Service) Run(ctx context.Context) { <-ctx.Done() }

/* ─────── consent ─────── */

func (s *Service) listConsents(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	out, err := s.store.userConsents(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Service) getConsent(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	c, err := s.store.userConsent(r.Context(), userID, r.PathValue("type"))
	if s.fail(w, err) {
		return
	}
	if c == nil {
		writeJSON(w, http.StatusOK, nil) // parity: Node returns null
		return
	}
	writeJSON(w, http.StatusOK, c)
}

func (s *Service) setConsent(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var b struct {
		ConsentType string `json:"consent_type"`
		Consented   *bool  `json:"consented"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || b.ConsentType == "" || b.Consented == nil {
		writeErr(w, http.StatusBadRequest, "validation_error", "consent_type and consented are required")
		return
	}
	c, err := s.store.setConsent(r.Context(), userID, b.ConsentType, *b.Consented)
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusCreated, c)
}

func (s *Service) updateConsent(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var b struct {
		Consented *bool `json:"consented"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || b.Consented == nil {
		writeErr(w, http.StatusBadRequest, "validation_error", "consented is required")
		return
	}
	ctype := r.PathValue("type")
	existing, err := s.store.userConsent(r.Context(), userID, ctype)
	if s.fail(w, err) {
		return
	}
	if existing == nil {
		writeErr(w, http.StatusNotFound, "not_found", "Consent not found")
		return
	}
	c, err := s.store.updateConsent(r.Context(), userID, ctype, *b.Consented)
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, c)
}

func (s *Service) withdrawNonEssential(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	n, err := s.store.withdrawNonEssential(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"updated": n})
}

/* ─────── export ─────── */

func (s *Service) export(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	appData := s.doExport(r.Context(), userID)
	writeJSON(w, http.StatusOK, map[string]any{
		"exportedAt":    time.Now().UTC().Format(time.RFC3339Nano),
		"formatVersion": "1.0",
		"userId":        userID,
		"data":          appData,
	})
}

/* ─────── deletion ─────── */

func (s *Service) createDeletion(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var b struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(r.Body).Decode(&b)
	exists, err := s.store.pendingExists(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	if exists {
		writeErr(w, http.StatusConflict, "conflict", "A pending data deletion request already exists")
		return
	}
	d, err := s.store.createDeletion(r.Context(), userID, optional(b.Reason))
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusCreated, d)
}

func (s *Service) myDeletion(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	d, err := s.store.myRequest(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	if d == nil {
		writeJSON(w, http.StatusOK, nil)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Service) cancelDeletion(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	d, err := s.store.cancelRequest(r.Context(), userID)
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "No pending deletion request found")
		return
	}
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Service) adminListDeletions(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	out, err := s.store.allRequests(r.Context(), r.URL.Query().Get("status"))
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Service) adminProcessDeletion(w http.ResponseWriter, r *http.Request) {
	adminID, ok := requireAdminUser(w, r)
	if !ok {
		return
	}
	var b struct {
		Status    string `json:"status"`
		AdminNote string `json:"admin_note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || !validStatus(b.Status) {
		writeErr(w, http.StatusBadRequest, "validation_error",
			"status must be one of in_progress, completed, rejected")
		return
	}
	id := r.PathValue("id")
	req, err := s.store.getRequest(r.Context(), id)
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "Deletion request not found")
		return
	}
	if s.fail(w, err) {
		return
	}
	if req.Status == "completed" {
		writeErr(w, http.StatusBadRequest, "bad_request", "Request already completed")
		return
	}
	// On completion, fire the app erasure webhook BEFORE marking done (parity).
	if b.Status == "completed" {
		s.doDeletion(r.Context(), req.UserID)
	}
	updated, err := s.store.updateRequest(r.Context(), id, b.Status, adminID, optional(b.AdminNote))
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

/* ─────── webhook seams ─────── */

// httpExport GETs <url>?userId=<id> and returns the JSON body as app data. A
// missing URL, non-2xx, or transport error yields an empty map (parity with the
// Node behavior: warn + empty export).
func httpExport(client *http.Client, rawURL string, log *slog.Logger) exportFn {
	return func(ctx context.Context, userID string) map[string]any {
		empty := map[string]any{}
		if rawURL == "" {
			log.Warn("GDPR_EXPORT_WEBHOOK_URL not configured — returning empty export")
			return empty
		}
		u := rawURL
		if strings.ContainsRune(rawURL, '?') {
			u += "&userId=" + url.QueryEscape(userID)
		} else {
			u += "?userId=" + url.QueryEscape(userID)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			log.Error("export webhook build failed", "err", err)
			return empty
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			log.Error("export webhook failed", "err", err)
			return empty
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			log.Warn("export webhook non-2xx", "status", resp.StatusCode)
			return empty
		}
		var data map[string]any
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		if err := json.Unmarshal(body, &data); err != nil {
			return empty
		}
		return data
	}
}

// httpDeletion POSTs {userId, action:"delete_user_data"} to the erasure webhook;
// failures are logged and swallowed (parity with the Node try/catch).
func httpDeletion(client *http.Client, rawURL string, log *slog.Logger) deletionFn {
	return func(ctx context.Context, userID string) {
		if rawURL == "" {
			log.Warn("GDPR_DELETION_WEBHOOK_URL not configured — skipping deletion callback")
			return
		}
		body, _ := json.Marshal(map[string]string{"userId": userID, "action": "delete_user_data"})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			log.Error("deletion webhook build failed", "err", err)
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			log.Error("deletion webhook failed", "err", err)
			return
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			log.Error("deletion webhook non-2xx", "status", resp.StatusCode)
		}
	}
}

/* ─────── helpers ─────── */

func (s *Service) fail(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, errConflict):
		writeErr(w, http.StatusConflict, "conflict", "conflict")
	case errors.Is(err, errCompleted):
		writeErr(w, http.StatusBadRequest, "bad_request", "Request already completed")
	default:
		s.log.Error("gdpr store error", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal_error", "unexpected error")
	}
	return true
}

func requireUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-User-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "missing verified identity")
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
		writeErr(w, http.StatusForbidden, "forbidden", "requires one of: service_role")
		return "", false
	}
	return userID, true
}

func validStatus(s string) bool {
	return s == "in_progress" || s == "completed" || s == "rejected"
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": code, "message": msg, "statusCode": status})
}
