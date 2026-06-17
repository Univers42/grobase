// Package newslettersvc is the Go port of the Node newsletter-service (R2).
//
// It owns the `newsletter.subscriber` + `newsletter.send_log` tables and ports
// both NestJS controllers: subscription (subscribe / confirm / unsubscribe +
// admin list/stats) and campaign (admin send / history). Outbound confirmation
// and campaign mail goes through an emailSender seam — by default an HTTP POST
// to EMAIL_SERVICE_URL/send, identical to the Node fetch — so behavior is
// byte-faithful and the seam is fakeable in tests. Running it inside the
// orchestrator binary instead of a ~50 MiB Node runtime is the R2 footprint win.
//
// Admin routes require role `service_role` (parity with the TS RolesGuard);
// public subscribe/confirm/unsubscribe are open, matching the Node controller.
package newslettersvc

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// emailSender abstracts the outbound /send call (fakeable in tests).
type emailSender func(ctx context.Context, to, subject, html, text string) error

// repo is the newsletter persistence seam (satisfied by *store; faked in tests).
type repo interface {
	bootstrap(ctx context.Context) error
	existing(ctx context.Context, email string) (int64, bool, *string, bool, error)
	reactivate(ctx context.Context, id int64, token string, firstName *string) (*Subscriber, error)
	insert(ctx context.Context, email string, firstName *string, token string) (*Subscriber, error)
	confirm(ctx context.Context, token string) (bool, error)
	unsubscribe(ctx context.Context, token string) (bool, error)
	listSubscribers(ctx context.Context, limit, offset int) ([]SubscriberSummary, error)
	stats(ctx context.Context) (Stats, error)
	confirmedEmails(ctx context.Context) ([]Recipient, error)
	logSend(ctx context.Context, subject string, count int, sentBy *string) error
	history(ctx context.Context, limit int) ([]SendLog, error)
}

// Service is the newsletter sub-service.
type Service struct {
	log       *slog.Logger
	store     repo
	send      emailSender
	baseURL   string // NEWSLETTER_BASE_URL — confirm links
	batchSize int    // NEWSLETTER_BATCH_SIZE
}

// New builds the service from env. The default email seam posts to
// EMAIL_SERVICE_URL/send (parity with the Node fetch).
func New(log *slog.Logger, pg *shared.Postgres) *Service {
	emailURL := shared.EnvStr("EMAIL_SERVICE_URL", "http://email-service:3030")
	client := &http.Client{Timeout: 10 * time.Second}
	return &Service{
		log:       log,
		store:     &store{pg: pg},
		baseURL:   shared.EnvStr("NEWSLETTER_BASE_URL", "http://localhost:8000/newsletter/v1"),
		batchSize: shared.EnvInt("NEWSLETTER_BATCH_SIZE", 5),
		send:      httpEmailSender(client, emailURL),
	}
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "newsletter" }

// Init ensures the newsletter tables exist (parity with onModuleInit).
func (s *Service) Init(ctx context.Context) error {
	if err := s.store.bootstrap(ctx); err != nil {
		return err
	}
	s.log.Info("newsletter tables ensured")
	return nil
}

// Mount registers the HTTP surface.
func (s *Service) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /subscribe", s.subscribe)
	mux.HandleFunc("GET /confirm/{token}", s.confirm)
	mux.HandleFunc("GET /unsubscribe/{token}", s.unsubscribe)
	mux.HandleFunc("GET /admin/subscribers", s.adminSubscribers)
	mux.HandleFunc("GET /admin/stats", s.adminStats)
	mux.HandleFunc("POST /admin/campaigns/send", s.campaignSend)
	mux.HandleFunc("GET /admin/campaigns/history", s.campaignHistory)
}

// Run has no background loop; it parks until shutdown.
func (s *Service) Run(ctx context.Context) { <-ctx.Done() }
