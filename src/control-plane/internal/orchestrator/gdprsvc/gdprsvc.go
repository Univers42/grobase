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
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
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
	log        *slog.Logger
	store      repo
	doExport   exportFn
	doDeletion deletionFn
}

// New builds the service from env, wiring the webhook seams to their default
// HTTP implementations.
func New(log *slog.Logger, pg *pg.Postgres) *Service {
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
	mux.HandleFunc("GET /consents", s.listConsents)
	mux.HandleFunc("POST /consents", s.setConsent)
	mux.HandleFunc("DELETE /consents/non-essential", s.withdrawNonEssential)
	mux.HandleFunc("GET /consents/{type}", s.getConsent)
	mux.HandleFunc("PUT /consents/{type}", s.updateConsent)
	mux.HandleFunc("GET /export", s.export)
	mux.HandleFunc("POST /deletion-requests", s.createDeletion)
	mux.HandleFunc("GET /deletion-requests/mine", s.myDeletion)
	mux.HandleFunc("DELETE /deletion-requests/mine", s.cancelDeletion)
	mux.HandleFunc("GET /deletion-requests/admin", s.adminListDeletions)
	mux.HandleFunc("POST /deletion-requests/admin/{id}/process", s.adminProcessDeletion)
}

// Run has no background loop; it parks until shutdown.
func (s *Service) Run(ctx context.Context) { <-ctx.Done() }
