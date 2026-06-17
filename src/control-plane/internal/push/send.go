package push

import (
	"context"

	"github.com/google/uuid"
)

const pushDeliveryHelp = "Push notification deliveries by outcome (success|failed)"

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
	res := s.fanOut(ctx, subs, body, notifID)
	if s.log != nil {
		s.log.Info("push send fan-out",
			"tenant", tenantID, "notification", notifID,
			"matched", res.Matched, "delivered", res.Delivered, "failed", res.Failed)
	}
	return res, nil
}

// fanOut delivers body to every matching subscription, tallying the outcome
// counters. One subscription failing never aborts the rest.
func (s *Service) fanOut(ctx context.Context, subs []liveSub, body []byte, notifID string) SendResult {
	res := SendResult{Notification: notifID, Matched: len(subs), Deliveries: make([]DeliveryResult, 0, len(subs))}
	for _, sub := range subs {
		dr := s.deliverOne(ctx, sub, body)
		res.Deliveries = append(res.Deliveries, dr)
		if dr.OK {
			res.Delivered++
			s.metrics.IncCounter("baas_push_deliveries_total", pushDeliveryHelp, "outcome", "success")
		} else {
			res.Failed++
			s.metrics.IncCounter("baas_push_deliveries_total", pushDeliveryHelp, "outcome", "failed")
		}
	}
	return res
}

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
