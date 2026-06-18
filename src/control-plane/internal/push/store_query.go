package push

import (
	"context"

	"github.com/jackc/pgx/v5"
)

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
