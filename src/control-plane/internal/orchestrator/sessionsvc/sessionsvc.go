// Package sessionsvc is the Go port of the Node session-service (R2 consolidation).
//
// It owns the `session.user_sessions` table and exposes the same user-scoped
// (create / list-mine / validate / extend / revoke / revoke-all) and admin
// (list-all / stats / force-revoke / cleanup) HTTP surface as the NestJS
// SessionService — a faithful port over shared.Postgres so a caller cannot tell
// which runtime served it. Running it inside the orchestrator binary instead of
// a ~50 MiB Node runtime is the R2 footprint win.
//
// Identity comes from the gateway-injected `X-Baas-User-Id` / `X-Baas-Role`
// headers (the gateway HMAC-verifies the signed envelope upstream and the
// orchestrator sits on the private docker network — same trust model as the
// adapter-registry Go port). Admin routes additionally require role
// `service_role`, mirroring the TS RolesGuard.
package sessionsvc

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// repo is the session persistence seam (satisfied by *store; faked in tests).
type repo interface {
	bootstrap(ctx context.Context) error
	create(ctx context.Context, userID, token, device, ip string) (*Session, error)
	userSessions(ctx context.Context, userID, currentToken string) ([]Session, error)
	validate(ctx context.Context, token string) (bool, *Session, error)
	extend(ctx context.Context, token string, days int) (*Session, error)
	revoke(ctx context.Context, id, userID string) error
	revokeAll(ctx context.Context, userID, except string) (int, error)
	activeSessions(ctx context.Context, userID string) ([]Session, error)
	stats(ctx context.Context) (Stats, error)
	forceRevoke(ctx context.Context, id string) error
	forceRevokeAll(ctx context.Context, userID string) (int, error)
	cleanupExpired(ctx context.Context) (int, error)
}

// Service is the session sub-service.
type Service struct {
	log   *slog.Logger
	store repo
}

// New builds the service from env (SESSION_TTL_DAYS default 7).
func New(log *slog.Logger, pg *shared.Postgres) *Service {
	return &Service{
		log:   log,
		store: &store{pg: pg, ttlDays: shared.EnvInt("SESSION_TTL_DAYS", 7)},
	}
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "session" }

// Init runs the schema bootstrap before the server starts serving (parity with
// the Nest onModuleInit). The orchestrator calls Init for any sub-service that
// implements it and treats a failure as fatal.
func (s *Service) Init(ctx context.Context) error {
	if err := s.store.bootstrap(ctx); err != nil {
		return err
	}
	s.log.Info("session schema initialized")
	return nil
}

// Mount registers the HTTP surface. Go's pattern mux gives literal segments
// (e.g. /sessions/admin/...) precedence over the {id} wildcard, so the user and
// admin routes coexist unambiguously.
func (s *Service) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /sessions", s.create)
	mux.HandleFunc("GET /sessions/mine", s.mine)
	mux.HandleFunc("POST /sessions/validate", s.validate)
	mux.HandleFunc("POST /sessions/extend", s.extend)
	mux.HandleFunc("POST /sessions/revoke-all", s.revokeAll)
	mux.HandleFunc("DELETE /sessions/{id}", s.revoke)

	mux.HandleFunc("GET /sessions/admin/all", s.adminAll)
	mux.HandleFunc("GET /sessions/admin/stats", s.adminStats)
	mux.HandleFunc("DELETE /sessions/admin/{id}", s.adminForceRevoke)
	mux.HandleFunc("POST /sessions/admin/users/{userId}/revoke-all", s.adminForceRevokeAll)
	mux.HandleFunc("POST /sessions/admin/cleanup", s.adminCleanup)
}

// Run has no background loop; it parks until shutdown.
func (s *Service) Run(ctx context.Context) { <-ctx.Done() }

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
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "token is required")
		return
	}
	sess, err := s.store.create(r.Context(), userID, b.Token, b.DeviceInfo, b.IPAddress)
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusCreated, sess)
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
	shared.WriteJSON(w, http.StatusOK, out)
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
	shared.WriteJSON(w, http.StatusOK, resp)
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
	shared.WriteJSON(w, http.StatusOK, map[string]any{"id": sess.ID, "expires_at": sess.ExpiresAt})
}

func (s *Service) revoke(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	err := s.store.revoke(r.Context(), r.PathValue("id"), userID)
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"revoked": true})
}

func (s *Service) revokeAll(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	n, err := s.store.revokeAll(r.Context(), userID, bearer(r))
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"revoked": n})
}

/* ─────── Admin endpoints (require service_role) ─────── */

func (s *Service) adminAll(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	out, err := s.store.activeSessions(r.Context(), r.URL.Query().Get("userId"))
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (s *Service) adminStats(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	st, err := s.store.stats(r.Context())
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, st)
}

func (s *Service) adminForceRevoke(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	err := s.store.forceRevoke(r.Context(), r.PathValue("id"))
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"revoked": true})
}

func (s *Service) adminForceRevokeAll(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	n, err := s.store.forceRevokeAll(r.Context(), r.PathValue("userId"))
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"revoked": n})
}

func (s *Service) adminCleanup(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	n, err := s.store.cleanupExpired(r.Context())
	if s.fail(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"deletedCount": n})
}

/* ─────── helpers ─────── */

// fail maps store errors to HTTP status (404/403/500). Returns true if it wrote
// a response (caller should stop).
func (s *Service) fail(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "session not found")
	case errors.Is(err, errForbidden):
		shared.WriteError(w, http.StatusForbidden, "forbidden", "not your session")
	default:
		s.log.Error("session store error", "err", err)
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", "unexpected error")
	}
	return true
}

// requireUser extracts the verified user id (gateway-injected signed-envelope
// header, legacy header in compat mode).
func requireUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-User-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "missing verified identity")
	return "", false
}

// requireAdmin enforces the service_role gate (parity with RolesGuard).
func requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	if _, ok := requireUser(w, r); !ok {
		return false
	}
	if r.Header.Get("X-Baas-Role") != "service_role" {
		shared.WriteError(w, http.StatusForbidden, "forbidden", "requires one of: service_role")
		return false
	}
	return true
}

// bearer pulls the raw token out of an Authorization: Bearer <token> header.
func bearer(r *http.Request) string {
	return strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
}
