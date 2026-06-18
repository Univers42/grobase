// Package sessionsvc is the Go port of the Node session-service (R2 consolidation).
//
// It owns the `session.user_sessions` table and exposes the same user-scoped
// (create / list-mine / validate / extend / revoke / revoke-all) and admin
// (list-all / stats / force-revoke / cleanup) HTTP surface as the NestJS
// SessionService — a faithful port over pg.Postgres so a caller cannot tell
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
	"log/slog"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
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
func New(log *slog.Logger, pg *pg.Postgres) *Service {
	return &Service{
		log:   log,
		store: &store{pg: pg, ttlDays: config.EnvInt("SESSION_TTL_DAYS", 7)},
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
