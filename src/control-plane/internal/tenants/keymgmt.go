package tenants

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// insertAPIKey inserts a key for the tenant identified by slug and returns the
// redacted projection (no secret).
const insertAPIKey = `
	WITH ins AS (
	  INSERT INTO public.tenant_api_keys
	         (tenant_id, name, key_prefix, key_hash, scopes, expires_at)
	  SELECT t.id, $2, $3, $4, $5, $6::timestamptz
	    FROM public.tenants t
	   WHERE t.slug = $1
	  RETURNING id, name, key_prefix, scopes, created_at, expires_at, last_used_at, revoked_at
	)
	SELECT ins.id::text, $1::text, ins.name, ins.key_prefix, ins.scopes,
	       ins.created_at::text, ins.expires_at::text,
	       ins.last_used_at::text, ins.revoked_at::text
	  FROM ins`

// IssueKey generates a new API key for the tenant identified by slug.
// Persists prefix+hash, returns the full cleartext key ONCE.
func (s *Service) IssueKey(ctx context.Context, slug string, req IssueKeyRequest) (IssueKeyResponse, error) {
	if req.Name == "" {
		return IssueKeyResponse{}, fmt.Errorf("name is required")
	}
	scopes := req.Scopes
	if len(scopes) == 0 {
		scopes = []string{"read", "write"}
	}
	prefix, fullKey, hash, err := generateKey()
	if err != nil {
		return IssueKeyResponse{}, err
	}
	expiresArg, err := parseExpiresArg(req.ExpiresAt)
	if err != nil {
		return IssueKeyResponse{}, err
	}
	row, err := s.queryOne(ctx, insertAPIKey, slug, req.Name, prefix, hash, scopes, expiresArg)
	if err != nil {
		return IssueKeyResponse{}, keyConflictOr(err, req.Name)
	}
	out, err := scanIssuedKey(row, req.Name)
	if err != nil {
		return IssueKeyResponse{}, err
	}
	return IssueKeyResponse{APIKey: out, Key: fullKey}, nil
}

// parseExpiresArg validates an optional RFC3339 expiry, returning the SQL arg
// (nil when unset) or an error when the value is malformed.
func parseExpiresArg(raw string) (any, error) {
	if raw == "" {
		return nil, nil
	}
	if _, perr := time.Parse(time.RFC3339, raw); perr != nil {
		return nil, fmt.Errorf("expires_at must be RFC3339")
	}
	return raw, nil
}

// keyConflictOr maps a unique violation to a friendly "name already exists"
// error, passing other errors through unchanged.
func keyConflictOr(err error, name string) error {
	if shared.IsUniqueViolation(err) {
		return fmt.Errorf("key name %q already exists for tenant", name)
	}
	return err
}

// scanIssuedKey scans the issued-key projection, mapping no-rows to ErrNotFound
// (the slug did not match a tenant) and a unique violation to a name conflict.
func scanIssuedKey(row pgx.Row, name string) (APIKey, error) {
	var out APIKey
	if err := row.Scan(&out.ID, &out.TenantID, &out.Name, &out.KeyPrefix,
		&out.Scopes, &out.CreatedAt, &out.ExpiresAt,
		&out.LastUsedAt, &out.RevokedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return APIKey{}, ErrNotFound
		}
		return APIKey{}, keyConflictOr(err, name)
	}
	return out, nil
}
