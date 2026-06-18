package functriggers

import "github.com/jackc/pgx/v5"

// scannable is the small surface common to pgx.Row and pgx.Rows.
type scannable interface {
	Scan(dest ...any) error
}

func scanTrigger(row scannable, tr *Trigger) error {
	return row.Scan(&tr.ID, &tr.TenantID, &tr.Name, &tr.FunctionName,
		&tr.EventTypes, &tr.Aggregates, &tr.Enabled,
		&tr.MaxAttempts, &tr.TimeoutMs, &tr.CreatedAt, &tr.UpdatedAt)
}

func scanDelivery(row scannable, d *Delivery) error {
	return row.Scan(&d.ID, &d.TriggerID, &d.TenantID, &d.FunctionName,
		&d.EventID, &d.Aggregate, &d.EventType, &d.Status, &d.Attempts,
		&d.LastError, &d.LastStatusCode, &d.NextAttemptAt,
		&d.DeliveredAt, &d.CreatedAt)
}

func collectDeliveries(rows pgx.Rows, out *[]Delivery) error {
	for rows.Next() {
		var d Delivery
		if err := scanDelivery(rows, &d); err != nil {
			return err
		}
		*out = append(*out, d)
	}
	return rows.Err()
}

func coalesceStrSlice(s []string, fallback string) []string {
	if len(s) == 0 {
		return []string{fallback}
	}
	return s
}
