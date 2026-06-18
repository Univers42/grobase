package funcsecrets

import (
	"context"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/jackc/pgx/v5"
)

// Set upserts an encrypted secret under the caller's tenant scope.
func (s *Service) Set(ctx context.Context, tenantID string, req SetRequest) (SecretMeta, error) {
	payload, err := s.enc.Encrypt(req.Value)
	if err != nil {
		return SecretMeta{}, err
	}
	var meta SecretMeta
	err = s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			INSERT INTO public.function_secrets
			       (tenant_id, function_name, key, encrypted, iv, tag, salt)
			VALUES ($1,$2,$3,$4,$5,$6,$7)
			ON CONFLICT (tenant_id, function_name, key) DO UPDATE
			   SET encrypted = EXCLUDED.encrypted, iv = EXCLUDED.iv,
			       tag = EXCLUDED.tag, salt = EXCLUDED.salt, updated_at = now()
			RETURNING key, function_name, updated_at::text`,
			tenantID, req.FunctionName, req.Key,
			payload.Encrypted, payload.IV, payload.Tag, payload.Salt)
		return row.Scan(&meta.Key, &meta.FunctionName, &meta.UpdatedAt)
	})
	return meta, err
}

// List returns secret metadata (no plaintext) for the caller's tenant.
func (s *Service) List(ctx context.Context, tenantID string) ([]SecretMeta, error) {
	out := make([]SecretMeta, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT key, function_name, updated_at::text
			  FROM public.function_secrets
			 ORDER BY function_name, key`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var m SecretMeta
			if err := rows.Scan(&m.Key, &m.FunctionName, &m.UpdatedAt); err != nil {
				return err
			}
			out = append(out, m)
		}
		return rows.Err()
	})
	return out, err
}

// Delete removes a secret by key (and optional function scope).
func (s *Service) Delete(ctx context.Context, tenantID, functionName, key string) error {
	return s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx,
			`DELETE FROM public.function_secrets WHERE key = $1 AND function_name = $2`,
			key, functionName)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// Resolve returns the decrypted key/value map for a tenant + function.
// Function-scoped secrets override tenant-wide ones (function_name = ”).
// Uses the admin pool because the runtime authenticates with the service token,
// not a tenant session.
func (s *Service) Resolve(ctx context.Context, tenantID, functionName string) (map[string]string, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT function_name, key, encrypted, iv, tag, salt
		  FROM public.function_secrets
		 WHERE tenant_id = $1 AND (function_name = '' OR function_name = $2)
		 ORDER BY function_name ASC`, tenantID, functionName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]string)
	for rows.Next() {
		if err := s.scanSecret(rows, tenantID, out); err != nil {
			return nil, err
		}
	}
	return out, rows.Err()
}

// scanSecret reads one row, decrypts it, and records it in out. A decrypt
// failure is logged and skipped (not fatal). ORDER BY function_name ASC puts ”
// (tenant-wide) first; the function-scoped row (if any) overwrites it.
func (s *Service) scanSecret(rows pgx.Rows, tenantID string, out map[string]string) error {
	var (
		fn  string
		key string
		p   adapterregistry.EncryptedPayload
	)
	if err := rows.Scan(&fn, &key, &p.Encrypted, &p.IV, &p.Tag, &p.Salt); err != nil {
		return err
	}
	plain, derr := s.enc.Decrypt(p)
	if derr != nil {
		s.log.Warn("secret decrypt failed", "tenant", tenantID, "key", key, "err", derr)
		return nil
	}
	out[key] = plain
	return nil
}
