package push

import (
	"context"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// Service orchestrates the push registry + the fan-out send. It owns the store
// (subscriptions CRUD, tenant_id bound) and the dispatcher (outbound HTTP POST
// with the SSRF guard). CONTROL-PLANE ONLY — it never touches RequestIdentity,
// the RLS GUCs, or the data plane.
type Service struct {
	store *store
	disp  *dispatcher
	log   *slog.Logger
}

// NewService wires the service from the shared Postgres pool. The token sealer is
// derived from PUSH_SECRET_KEY (nil when unset — valid for a webhook-only
// deployment; an attempt to store a provider token without a key fails fast).
func NewService(db *pg.Postgres, log *slog.Logger) *Service {
	return &Service{
		store: newStore(db, newSealerFromEnv()),
		disp:  newDispatcher(),
		log:   log,
	}
}

// EnsureSchema verifies migration 056 ran.
func (s *Service) EnsureSchema(ctx context.Context) error { return s.store.EnsureSchema(ctx) }

// Register validates the request, applies the SSRF guard to target_url (a
// subscription pointing at an internal address is rejected BEFORE it is stored),
// and inserts the row under tenantID.
func (s *Service) Register(ctx context.Context, tenantID string, req RegisterRequest) (Subscription, error) {
	if err := req.Validate(); err != nil {
		return Subscription{}, err
	}
	// Load-bearing: refuse a target that resolves to internal space at REGISTER
	// time, so a blocked subscription never even lands in the table.
	if err := guardTarget(req.TargetURL); err != nil {
		return Subscription{}, err
	}
	return s.store.Register(ctx, tenantID, req)
}

// List returns the tenant's live subscriptions (sealed tokens never exposed).
func (s *Service) List(ctx context.Context, tenantID string) ([]Subscription, error) {
	return s.store.List(ctx, tenantID)
}

// Revoke soft-deletes a subscription scoped to tenantID (cross-tenant -> ErrNotFound).
func (s *Service) Revoke(ctx context.Context, tenantID, id string) error {
	return s.store.Revoke(ctx, tenantID, id)
}

// Send (the fan-out send) and deliverOne live in send.go.
