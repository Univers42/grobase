package push

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// store owns CRUD on public.push_subscriptions. EVERY query binds tenant_id in
// its WHERE — the push service runs as the BYPASSRLS service_role, so this
// explicit scope IS the per-tenant wall (a send in one tenant can never read or
// deliver to another tenant's subscriptions even though RLS is bypassed for the
// owning role). This is the SAME discipline webhooks' dispatcher applies (the
// `AND tenant_id = $1` predicate is authoritative, not optional).
type store struct {
	db     *shared.Postgres
	sealer *tokenSealer
}

func newStore(db *shared.Postgres, sealer *tokenSealer) *store {
	return &store{db: db, sealer: sealer}
}

// liveSub is the internal row including the sealed token (never exported).
type liveSub struct {
	Subscription
	tokenEnc []byte
}

// EnsureSchema fails fast if migration 056 has not run.
func (s *store) EnsureSchema(ctx context.Context) error {
	rows, err := s.db.AdminQuery(ctx, `SELECT 1 FROM information_schema.tables
		 WHERE table_schema='public' AND table_name='push_subscriptions'`)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.push_subscriptions missing — run migration 056_push_subscriptions.sql")
	}
	return nil
}

// Register inserts a subscription under tenantID. The provider token (if any) is
// AES-256-GCM sealed before storage; token_enc stays NULL for the webhook channel.
func (s *store) Register(ctx context.Context, tenantID string, req RegisterRequest) (Subscription, error) {
	tokenEnc, err := s.sealer.seal(req.Token)
	if err != nil {
		return Subscription{}, err
	}
	var sub Subscription
	err = s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			INSERT INTO public.push_subscriptions
			       (tenant_id, user_id, channel, target_url, token_enc, label)
			VALUES ($1, NULLIF($2,''), $3, $4, $5, $6)
			RETURNING id::text, tenant_id, COALESCE(user_id,''), channel, target_url,
			          label, (token_enc IS NOT NULL),
			          created_at::text, COALESCE(revoked_at::text,'')`,
			tenantID, req.UserID, req.Channel, req.TargetURL, tokenEnc, req.Label)
		return row.Scan(&sub.ID, &sub.TenantID, &sub.UserID, &sub.Channel, &sub.TargetURL,
			&sub.Label, &sub.HasToken, &sub.CreatedAt, &sub.RevokedAt)
	})
	return sub, err
}

// List returns the LIVE (not revoked) subscriptions for tenantID, newest first.
func (s *store) List(ctx context.Context, tenantID string) ([]Subscription, error) {
	out := make([]Subscription, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, tenant_id, COALESCE(user_id,''), channel, target_url,
			       label, (token_enc IS NOT NULL),
			       created_at::text, COALESCE(revoked_at::text,'')
			  FROM public.push_subscriptions
			 WHERE tenant_id = $1 AND revoked_at IS NULL
			 ORDER BY created_at DESC`, tenantID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var sub Subscription
			if err := rows.Scan(&sub.ID, &sub.TenantID, &sub.UserID, &sub.Channel,
				&sub.TargetURL, &sub.Label, &sub.HasToken, &sub.CreatedAt, &sub.RevokedAt); err != nil {
				return err
			}
			out = append(out, sub)
		}
		return rows.Err()
	})
	return out, err
}

// Revoke soft-deletes a subscription (revoked_at = now()) scoped to tenantID. A
// subscription belonging to another tenant is invisible (the WHERE tenant_id
// wall), so RowsAffected==0 -> ErrNotFound — a cross-tenant DELETE can never
// touch another tenant's row.
func (s *store) Revoke(ctx context.Context, tenantID, id string) error {
	return s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE public.push_subscriptions
			   SET revoked_at = now()
			 WHERE id = $1::uuid AND tenant_id = $2 AND revoked_at IS NULL`, id, tenantID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// Matching loads the LIVE subscriptions a send fans out to. The send's optional
// userID narrows the set (NULL user_id subscriptions are tenant-wide and always
// match; a userID-scoped send also includes those, plus the ones for that user).
// tenant_id is bound — SR2's rows in another tenant can never be returned.
func (s *store) Matching(ctx context.Context, tenantID, userID string) ([]liveSub, error) {
	out := make([]liveSub, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, tenant_id, COALESCE(user_id,''), channel, target_url,
			       label, token_enc, created_at::text
			  FROM public.push_subscriptions
			 WHERE tenant_id = $1 AND revoked_at IS NULL
			   AND ($2 = '' OR user_id IS NULL OR user_id = $2)
			 ORDER BY created_at`, tenantID, userID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var ls liveSub
			if err := rows.Scan(&ls.ID, &ls.TenantID, &ls.UserID, &ls.Channel,
				&ls.TargetURL, &ls.Label, &ls.tokenEnc, &ls.CreatedAt); err != nil {
				return err
			}
			ls.HasToken = len(ls.tokenEnc) > 0
			out = append(out, ls)
		}
		return rows.Err()
	})
	return out, err
}

// openToken decrypts a subscription's sealed provider token (for the Bearer auth
// header on an FCM delivery). A webhook subscription has no token -> "".
func (s *store) openToken(ls liveSub) (string, error) {
	return s.sealer.open(ls.tokenEnc)
}
