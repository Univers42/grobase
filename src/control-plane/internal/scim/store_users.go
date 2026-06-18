package scim

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
)

// store_users.go — the scim_users mapping type + its insert/read queries. Split
// out of store.go to keep each file at ≤5 funcs; behavior is byte-identical.

// userRecord is the persisted SCIM user mapping (the wall-scoped resource).
type userRecord struct {
	SCIMID      string
	TenantID    string
	OrgID       string
	UserName    string
	UserID      string
	DisplayName string
	Emails      []SCIMEmail
	Active      bool
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// InsertUser creates the SCIM user mapping row. Keyed UNIQUE(tenant_id, scim_id)
// — the per-tenant namespace. emails is serialized as jsonb.
func (s *store) InsertUser(ctx context.Context, u userRecord) error {
	emailJSON, _ := json.Marshal(u.Emails)
	return s.db.AdminExec(ctx, `
		INSERT INTO public.scim_users
		  (tenant_id, org_id, scim_id, user_name, user_id, display_name, emails, active)
		VALUES ($1, NULLIF($2,''), $3, $4, $5, $6, $7::jsonb, $8)`,
		u.TenantID, u.OrgID, u.SCIMID, u.UserName, u.UserID,
		u.DisplayName, string(emailJSON), u.Active)
}

// GetUser fetches one SCIM user by (tenantID, scimID). ErrNotFound if absent —
// note the tenant_id bind: a T2 token can never resolve a T1 scim_id.
func (s *store) GetUser(ctx context.Context, tenantID, scimID string) (userRecord, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT scim_id, tenant_id, COALESCE(org_id,''), user_name, user_id,
		       display_name, emails::text, active, created_at, updated_at
		  FROM public.scim_users
		 WHERE tenant_id = $1 AND scim_id = $2`, tenantID, scimID)
	if err != nil {
		return userRecord{}, err
	}
	return scanUser(rows)
}

// FindByUserName resolves a SCIM user by (tenantID, userName) — backs the
// filter=userName eq "x" query. Case-insensitive (matches the lower(user_name)
// index). ErrNotFound when no row.
func (s *store) FindByUserName(ctx context.Context, tenantID, userName string) (userRecord, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT scim_id, tenant_id, COALESCE(org_id,''), user_name, user_id,
		       display_name, emails::text, active, created_at, updated_at
		  FROM public.scim_users
		 WHERE tenant_id = $1 AND lower(user_name) = lower($2)
		 LIMIT 1`, tenantID, userName)
	if err != nil {
		return userRecord{}, err
	}
	return scanUser(rows)
}

// scanUser reads exactly one userRecord from a result set, ErrNotFound if empty.
func scanUser(rows pgx.Rows) (userRecord, error) {
	defer rows.Close()
	if !rows.Next() {
		if rows.Err() != nil {
			return userRecord{}, rows.Err()
		}
		return userRecord{}, ErrNotFound
	}
	var u userRecord
	var emailJSON string
	if err := rows.Scan(&u.SCIMID, &u.TenantID, &u.OrgID, &u.UserName, &u.UserID,
		&u.DisplayName, &emailJSON, &u.Active, &u.CreatedAt, &u.UpdatedAt); err != nil {
		return userRecord{}, err
	}
	u.Emails = []SCIMEmail{}
	if emailJSON != "" {
		_ = json.Unmarshal([]byte(emailJSON), &u.Emails)
	}
	return u, nil
}
