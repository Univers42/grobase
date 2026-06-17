package push

import (
	"context"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/google/uuid"
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
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
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

// Send fans a notification out to every live matching subscription for tenantID.
// Each delivery re-applies the SSRF guard at the moment of the POST (send-time
// re-check). The result reports matched/delivered/failed counts and per-
// subscription outcomes. A send to a tenant with no subscriptions is a valid
// no-op (matched=0). Delivery to one subscription failing never aborts the rest.
func (s *Service) Send(ctx context.Context, tenantID string, req SendRequest) (SendResult, error) {
	if err := req.Validate(); err != nil {
		return SendResult{}, err
	}
	subs, err := s.store.Matching(ctx, tenantID, req.UserID)
	if err != nil {
		return SendResult{}, err
	}
	notifID := uuid.NewString()
	body, err := marshalNotification(tenantID, notifID, req)
	if err != nil {
		return SendResult{}, err
	}

	res := SendResult{Notification: notifID, Matched: len(subs), Deliveries: make([]DeliveryResult, 0, len(subs))}
	for _, sub := range subs {
		dr := s.deliverOne(ctx, sub, body)
		res.Deliveries = append(res.Deliveries, dr)
		if dr.OK {
			res.Delivered++
			shared.IncCounter("baas_push_deliveries_total", pushDeliveryHelp, "outcome", "success")
		} else {
			res.Failed++
			shared.IncCounter("baas_push_deliveries_total", pushDeliveryHelp, "outcome", "failed")
		}
	}
	if s.log != nil {
		s.log.Info("push send fan-out",
			"tenant", tenantID, "notification", notifID,
			"matched", res.Matched, "delivered", res.Delivered, "failed", res.Failed)
	}
	return res, nil
}

const pushDeliveryHelp = "Push notification deliveries by outcome (success|failed)"

// deliverOne resolves the (optional) sealed provider token, then POSTs the
// payload via the dispatcher (which re-applies the SSRF guard). It NEVER returns
// an error — a per-subscription failure is reported in the DeliveryResult so the
// fan-out continues.
func (s *Service) deliverOne(ctx context.Context, sub liveSub, body []byte) DeliveryResult {
	dr := DeliveryResult{SubscriptionID: sub.ID, Channel: sub.Channel}
	bearer, err := s.store.openToken(sub)
	if err != nil {
		dr.Error = "open token: " + err.Error()
		return dr
	}
	status, err := s.disp.deliver(ctx, sub.TargetURL, bearer, body)
	dr.StatusCode = status
	if err != nil {
		dr.Error = err.Error()
		return dr
	}
	dr.OK = true
	return dr
}
