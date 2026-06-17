package adapterregistry

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/jackc/pgx/v5"
)

// GetConnection returns the connection info for the data plane. For an INLINE
// mount it decrypts and returns the DSN (today's path, byte-for-byte). For a
// cred-ref mount (S2) it returns the credential_ref so the data plane resolves
// the real DSN itself via its CredentialProvider registry — no plaintext DSN
// ever travels back through the control plane for a Vault-backed mount.
func (s *Service) GetConnection(ctx context.Context, userID, id string) (ConnectionResult, error) {
	var (
		engine     string
		isolation  string
		payload    EncryptedPayload
		provider   *string
		reference  *string
		version    *string
		cmekWrap   []byte
		cmekKeyPtr *string
	)
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		// EXPLICIT tenant scope (not just the RLS policy): the control-plane DB
		// role owns/bypasses RLS on tenant_databases, so without `AND
		// tenant_id = $2` a mount's UUID would be a bearer capability — ANY
		// valid tenant key + the dbId would resolve (and read) ANOTHER
		// tenant's mount. The whole tenant_owned safety model rests on this
		// caller==owner check at resolve time. `userID` is the caller tenant
		// the query-router forwards as X-Tenant-Id.
		row := tx.QueryRow(ctx,
			`SELECT engine, isolation, connection_enc, connection_iv, connection_tag, connection_salt,
			        cred_provider, cred_reference, cred_version,
			        cmek_wrapped_dek, cmek_kms_key_id
			   FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2`, id, userID)
		err := row.Scan(&engine, &isolation, &payload.Encrypted, &payload.IV, &payload.Tag, &payload.Salt,
			&provider, &reference, &version,
			&cmekWrap, &cmekKeyPtr)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		// fire-and-forget health timestamp, same intent as the Node service
		_, _ = tx.Exec(ctx, `UPDATE public.tenant_databases SET last_healthy_at = now() WHERE id = $1 AND tenant_id = $2`, id, userID)
		return nil
	})
	if err != nil {
		return ConnectionResult{}, err
	}

	// Cred-ref mount: surface provider+reference (NO decrypt — there is no
	// ciphertext). The DB XOR check guarantees an inline row never reaches here
	// with cred_* set, so a populated cred_provider is unambiguously a ref mount.
	if provider != nil && *provider != "" {
		result := ConnectionResult{
			Engine:    engine,
			Isolation: isolation,
			CredentialRef: &CredentialRefInput{
				Provider:  *provider,
				Reference: derefStr(reference),
				Version:   derefStr(version),
			},
		}
		if name, pkg, ok := s.packageForTenant(ctx, userID); ok {
			result.Package = name
			result.CapabilityOverrides = pkg.CapabilityOverrides()
		}
		return result, nil
	}

	// CMEK / BYOK (D4.8): a cmek-envelope mount (cmek_wrapped_dek IS NOT NULL)
	// decrypts via the EXTERNAL KMS — unwrap the DEK, then AES-GCM-open the DSN.
	// It integrates with the SAME tag-cache + singleflight as the inline path, so
	// the KMS is hit ONCE per ciphertext (NOT per request). If CMEK is disabled or
	// no provider is wired, a stored cmek row cannot be served — fail closed
	// rather than silently treat the DEK-ciphertext as a master-key ciphertext.
	// If the KMS cannot unwrap (key revoked/deleted), cmek.Open returns
	// ErrShredded and the caller gets a non-2xx — crypto-shred by construction.
	usingCMEK := len(cmekWrap) > 0
	if usingCMEK && (!s.cmekEnabled || s.kms == nil) {
		return ConnectionResult{}, errors.New("cmek mount stored but CMEK is disabled/unconfigured — cannot decrypt")
	}

	// decrypt only when the ciphertext changed since the last call (the auth tag
	// is a cryptographic digest of payload+key — equal tag ⇒ equal plaintext).
	// Concurrent misses for one mount coalesce (sf); distinct cold inline mounts
	// queue on the Encryptor's scryptSlots. See connCache.
	var conn string
	tag := string(payload.Tag)
	if v, ok := s.connCache.Load(id); ok {
		if e, ok := v.(connCacheEntry); ok && e.tag == tag {
			conn = e.conn
		}
	}
	if conn == "" {
		v, derr, _ := s.sf.Do(id+"\x00"+tag, func() (any, error) {
			if v, ok := s.connCache.Load(id); ok {
				if e, ok := v.(connCacheEntry); ok && e.tag == tag {
					return e.conn, nil
				}
			}
			var (
				c   string
				err error
			)
			if usingCMEK {
				// Unwrap the DEK via the KMS using the row's stored key id, then
				// AES-GCM-open the DEK-encrypted DSN (enc||tag reassembled).
				ct := cmek.JoinCiphertext(payload.Encrypted, payload.Tag)
				plain, oErr := cmek.Open(ctx, s.kms, derefStr(cmekKeyPtr), cmekWrap, payload.IV, ct)
				if oErr != nil {
					return nil, oErr
				}
				c = string(plain)
			} else {
				c, err = s.enc.Decrypt(payload)
				if err != nil {
					return nil, err
				}
			}
			s.connCache.Store(id, connCacheEntry{tag: tag, conn: c})
			return c, nil
		})
		if derr != nil {
			return ConnectionResult{}, derr
		}
		conn, _ = v.(string)
	}
	result := ConnectionResult{Engine: engine, ConnectionString: conn, Isolation: isolation}
	// Phase 4 tiering: stamp the tenant's package tier mask so the data plane
	// enforces capability gating (403) + rate limiting (429). Resolved from the
	// tenant's `plan`; a no-op when PACKAGE_ENFORCEMENT=0.
	if name, pkg, ok := s.packageForTenant(ctx, userID); ok {
		result.Package = name
		result.CapabilityOverrides = pkg.CapabilityOverrides()
	}
	return result, nil
}

// Remove deletes a database by id (admin scope, bypasses RLS).
func (s *Service) Remove(ctx context.Context, id string) error {
	rows, err := s.db.AdminQuery(ctx,
		`DELETE FROM public.tenant_databases WHERE id = $1 RETURNING id`, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return ErrNotFound
	}
	return nil
}

// RemoveScoped deletes a mount by id, CALLER-SCOPED — the SQL binds BOTH the id
// AND the caller's tenant_id, so a mount UUID is NEVER a bearer capability: a
// caller can only ever delete its OWN mount, even if it guessed another tenant's
// uuid. This is the self-serve builder's delete (DELETE /databases/{id}/self),
// distinct from the admin Remove (DELETE /databases/{id}) which bypasses RLS for
// operator teardown. `userID` is the caller tenant the query-router forwards as
// X-Baas-Tenant-Id (the same scope GetConnection/List use). The connCache entry
// for the id is invalidated so a stale decrypted DSN cannot survive the delete.
func (s *Service) RemoveScoped(ctx context.Context, userID, id string) error {
	rows, err := s.db.AdminQuery(ctx,
		`DELETE FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2 RETURNING id`, id, userID)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return ErrNotFound
	}
	s.connCache.Delete(id)
	return nil
}
