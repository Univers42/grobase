package provision

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// decideRequest builds the POST /permissions/decide request, propagating the
// internal service token (ServiceTokenGuard) and trace headers.
func (b *sqlBackend) decideRequest(ctx context.Context, userID, resourceType, resourceName, op string) (*http.Request, error) {
	body, _ := json.Marshal(map[string]any{
		"user":          map[string]string{"id": userID},
		"resource_type": resourceType,
		"resource_name": resourceName,
		"op":            op,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.decideURL+"/permissions/decide", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if b.serviceToken != "" {
		req.Header.Set("X-Service-Token", b.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)
	return req, nil
}

// queryOne reduces a multi-row result to a single-row scanner returning
// pgx.ErrNoRows when empty (mirrors tenants.singleRow).
func (b *sqlBackend) queryOne(ctx context.Context, sql string, args ...any) (interface{ Scan(...any) error }, error) {
	rows, err := b.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return &singleRow{rows: rows}, nil
}

type singleRow struct{ rows pgx.Rows }

func (s *singleRow) Scan(dest ...any) error {
	defer s.rows.Close()
	if !s.rows.Next() {
		if err := s.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return s.rows.Scan(dest...)
}

// namespaced builds the slug-scoped DB role name. Centralized so the format
// lives in exactly one place (mirrors NamespacedRoleName / RoleKey).
func namespaced(slug, role string) string { return slug + ":" + role }

func nullable(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}
