package adapterregistry

import (
	"context"
	"errors"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Register stores a mount under tenant RLS. An INLINE mount encrypts the
// connection string at rest (today's path, byte-for-byte). A cred-ref mount (S2)
// stores cred_provider/cred_reference/cred_version with NO encryption — the data
// plane resolves the real DSN at query time via its CredentialProvider registry.
func (s *Service) Register(ctx context.Context, userID string, req RegisterDatabaseRequest) (RegisterResult, error) {
	isolation := req.Isolation
	if isolation == "" {
		isolation = "shared_rls"
	}

	// Phase 4 tiering: the engine must be in the tenant's package, and the
	// tenant must be under its package's max_mounts cap. A no-op when
	// PACKAGE_ENFORCEMENT=0 / manifest unavailable.
	_, pkg, tiered := s.packageForTenant(ctx, userID)
	if tiered && !pkg.AllowsEngine(req.Engine) {
		return RegisterResult{}, fmt.Errorf("%w: %q (package allows %v)", ErrEngineNotInPackage, req.Engine, pkg.Engines)
	}

	usingRef := req.CredentialRef.set()

	// CMEK / BYOK (D4.8): an inline mount is sealed via the external KMS envelope
	// when CMEK is enabled AND a key id is in play (request kms_key_id, else the
	// env default). cred-ref mounts NEVER use CMEK (they store no ciphertext).
	// When CMEK is disabled / no key id resolves, usingCMEK stays false and the
	// EXACT existing inline path runs (byte-parity baseline). Computed BEFORE the
	// S2 max-tier check because CMEK is a valid non-plaintext-at-rest path: the
	// DSN is only recoverable with the customer's KMS key, so a max-tier tenant
	// may use it (the thing S2 forbids is platform-recoverable plaintext at rest).
	cmekKeyID := req.KMSKeyID
	if cmekKeyID == "" {
		cmekKeyID = s.cmekDefaultKeyID
	}
	usingCMEK := s.cmekEnabled && !usingRef && cmekKeyID != ""

	// S2 / G-Vault: a tenant whose tier's security_mode is "max" may NOT register
	// an inline plaintext DSN under the PLATFORM master key — it must use a
	// credential_ref OR a CMEK envelope so no platform-recoverable plaintext is
	// encrypted-at-rest for it. Gated on the resolved tier; a no-op when tiering
	// is disabled or the tier is not max (parity for every non-max tenant), and
	// exempted when the inline DSN will be CMEK-sealed.
	if tiered && !usingRef && !usingCMEK && pkg.SecurityMode == "max" {
		return RegisterResult{}, ErrPlaintextDsnForbidden
	}

	// Encrypt ONLY for an inline path. A cred-ref mount stores no ciphertext, so
	// it never pays (nor risks) the scrypt KDF / AES-GCM seal. The inline path is
	// either the platform-master-key seal (today) or the CMEK envelope seal: both
	// fill connection_enc/iv/tag; CMEK additionally yields a wrapped DEK + key id.
	var (
		payload  EncryptedPayload
		cmekWrap []byte
	)
	switch {
	case usingCMEK:
		wrapped, iv, ct, sErr := cmek.Seal(ctx, s.kms, cmekKeyID, []byte(req.ConnectionString))
		if sErr != nil {
			return RegisterResult{}, fmt.Errorf("cmek seal: %w", sErr)
		}
		enc, tag, spErr := cmek.SplitCiphertext(ct)
		if spErr != nil {
			return RegisterResult{}, spErr
		}
		// Reuse the inline columns: enc/iv/tag carry the DEK-encrypted DSN. No
		// scrypt salt (CMEK has no KDF), so connection_salt stays NULL.
		payload = EncryptedPayload{Encrypted: enc, IV: iv, Tag: tag}
		cmekWrap = wrapped
	case !usingRef:
		var err error
		payload, err = s.enc.Encrypt(req.ConnectionString)
		if err != nil {
			return RegisterResult{}, err
		}
	}

	var out RegisterResult
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		// Mount-quota check INSIDE the tx so the count is consistent with the
		// insert (no TOCTOU under concurrent registrations).
		if tiered && pkg.PoolPolicy.MaxMounts > 0 {
			var count int
			if err := tx.QueryRow(ctx,
				`SELECT count(*) FROM public.tenant_databases WHERE tenant_id = $1`, userID).Scan(&count); err != nil {
				return err
			}
			if count >= pkg.PoolPolicy.MaxMounts {
				return ErrMountQuotaExceeded
			}
		}
		if usingRef {
			// Cred-ref row: NULL inline-encrypted columns, populated cred_*.
			// version may be empty (NULL) — the data plane treats absent as latest.
			var version any
			if req.CredentialRef.Version != "" {
				version = req.CredentialRef.Version
			}
			row := tx.QueryRow(ctx,
				`INSERT INTO public.tenant_databases
				   (tenant_id, engine, name, cred_provider, cred_reference, cred_version, isolation)
				 VALUES ($1,$2,$3,$4,$5,$6,$7)
				 RETURNING id, engine, name, created_at::text`,
				userID, req.Engine, req.Name,
				req.CredentialRef.Provider, req.CredentialRef.Reference, version, isolation,
			)
			return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
		}
		if usingCMEK {
			// CMEK-envelope row: DEK-encrypted DSN in enc/iv/tag (NO salt — no KDF)
			// + the KMS-wrapped DEK + the KMS key id. cred_* stay NULL. The 3-way
			// DB check (migration 061 / EnsureSchema) enforces this exact shape.
			row := tx.QueryRow(ctx,
				`INSERT INTO public.tenant_databases
				   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag,
				    cmek_wrapped_dek, cmek_kms_key_id, isolation)
				 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
				 RETURNING id, engine, name, created_at::text`,
				userID, req.Engine, req.Name,
				payload.Encrypted, payload.IV, payload.Tag, cmekWrap, cmekKeyID, isolation,
			)
			return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
		}
		row := tx.QueryRow(ctx,
			`INSERT INTO public.tenant_databases
			   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, connection_salt, isolation)
			 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
			 RETURNING id, engine, name, created_at::text`,
			userID, req.Engine, req.Name,
			payload.Encrypted, payload.IV, payload.Tag, payload.Salt, isolation,
		)
		return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
	})
	if errors.Is(err, ErrMountQuotaExceeded) {
		return RegisterResult{}, err
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return RegisterResult{}, ErrConflict
		}
		return RegisterResult{}, err
	}
	return out, nil
}
