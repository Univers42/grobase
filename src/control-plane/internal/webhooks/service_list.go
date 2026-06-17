package webhooks

import (
	"context"

	"github.com/jackc/pgx/v5"
)

const selectDeliveryCols = `
	SELECT id, subscription_id::text, tenant_id, event_id, aggregate, event_type,
	       status, attempts, last_error, last_status_code,
	       next_attempt_at::text, delivered_at::text, created_at::text`

// Deliveries returns the most recent delivery attempts for a subscription.
func (s *Service) Deliveries(ctx context.Context, tenantID, subscriptionID string, limit int) ([]Delivery, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	out := make([]Delivery, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, selectDeliveryCols+`
			  FROM public.webhook_deliveries
			 WHERE subscription_id = $1
			 ORDER BY created_at DESC
			 LIMIT $2`, subscriptionID, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		return collectDeliveries(rows, &out)
	})
	return out, err
}

func collectDeliveries(rows pgx.Rows, out *[]Delivery) error {
	for rows.Next() {
		var d Delivery
		if err := rows.Scan(&d.ID, &d.SubscriptionID, &d.TenantID, &d.EventID,
			&d.Aggregate, &d.EventType, &d.Status, &d.Attempts,
			&d.LastError, &d.LastStatusCode, &d.NextAttemptAt,
			&d.DeliveredAt, &d.CreatedAt); err != nil {
			return err
		}
		*out = append(*out, d)
	}
	return rows.Err()
}
