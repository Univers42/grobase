package webhooks

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// lookupMatching reads the active subscription set for the tenant and filters
// the event-type/aggregate match in-Go. For modest sub counts (<10k/tenant)
// in-Go matching on the TEXT[] columns is cheaper than a SQL array filter.
//
// The `tenant_id = $1` predicate is the AUTHORITATIVE tenant scope and is NOT
// optional: this dispatcher connects to the system Postgres as the table-owning
// `postgres` superuser, so the per-tenant RLS policy on webhook_subscriptions
// is silently bypassed (owner + ENABLE-not-FORCE). Without it, a write in one
// tenant would POST that tenant's row payload to EVERY tenant's webhook URL —
// a cross-tenant data-exfiltration breach. We scope explicitly in SQL.
func (d *Dispatcher) lookupMatching(ctx context.Context, tenantID, aggregate, eventType string) ([]Subscription, error) {
	if tenantID == "" {
		return nil, nil
	}
	subs := make([]Subscription, 0)
	err := d.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, selectSubscriptionCols+`
			  FROM public.webhook_subscriptions
			 WHERE active = true AND tenant_id = $1`, tenantID)
		if err != nil {
			return err
		}
		defer rows.Close()
		return collectMatching(rows, &subs, aggregate, eventType)
	})
	return subs, err
}

func collectMatching(rows rowsScanner, subs *[]Subscription, aggregate, eventType string) error {
	for rows.Next() {
		var sub Subscription
		if err := scanSubscription(rows, &sub); err != nil {
			return err
		}
		if sub.matches(aggregate, eventType) {
			*subs = append(*subs, sub)
		}
	}
	return rows.Err()
}
