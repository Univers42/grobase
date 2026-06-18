package gdprsvc

import (
	"context"
	"time"
)

/* ─────── consent ─────── */

func (s *store) userConsents(ctx context.Context, userID string) ([]Consent, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT `+consentCols+` FROM gdpr.user_consent WHERE user_id = $1 ORDER BY consent_type ASC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Consent{}
	for rows.Next() {
		var c Consent
		if err := scanConsent(rows, &c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *store) userConsent(ctx context.Context, userID, ctype string) (*Consent, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT `+consentCols+` FROM gdpr.user_consent WHERE user_id = $1 AND consent_type = $2 LIMIT 1`,
		userID, ctype)
	if err != nil {
		return nil, err
	}
	return firstConsent(rows, nil)
}

func (s *store) setConsent(ctx context.Context, userID, ctype string, consented bool) (*Consent, error) {
	now := time.Now()
	var grantedAt, revokedAt *time.Time
	if consented {
		grantedAt = &now
	} else {
		revokedAt = &now
	}
	rows, err := s.pg.AdminQuery(ctx,
		`INSERT INTO gdpr.user_consent (user_id, consent_type, is_granted, granted_at, revoked_at)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (user_id, consent_type) DO UPDATE SET
		   is_granted = EXCLUDED.is_granted,
		   granted_at = CASE WHEN EXCLUDED.is_granted THEN now() ELSE gdpr.user_consent.granted_at END,
		   revoked_at = CASE WHEN NOT EXCLUDED.is_granted THEN now() ELSE NULL END
		 RETURNING `+consentCols,
		userID, ctype, consented, grantedAt, revokedAt)
	if err != nil {
		return nil, err
	}
	return firstConsent(rows, errNotFound)
}

func (s *store) updateConsent(ctx context.Context, userID, ctype string, consented bool) (*Consent, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE gdpr.user_consent
		 SET is_granted = $3,
		     granted_at = CASE WHEN $3 THEN now() ELSE granted_at END,
		     revoked_at = CASE WHEN NOT $3 THEN now() ELSE NULL END
		 WHERE user_id = $1 AND consent_type = $2 RETURNING `+consentCols,
		userID, ctype, consented)
	if err != nil {
		return nil, err
	}
	return firstConsent(rows, errNotFound)
}

func (s *store) withdrawNonEssential(ctx context.Context, userID string) (int, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE gdpr.user_consent SET is_granted = false, revoked_at = now()
		 WHERE user_id = $1 AND consent_type != 'essential' AND is_granted = true RETURNING id`, userID)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		n++
	}
	return n, rows.Err()
}
