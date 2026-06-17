package adapterregistry

import (
	"context"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/jackc/pgx/v5"
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
	// Phase 4 tiering: the engine must be in the tenant's package (the
	// max_mounts cap is enforced inside the tx). A no-op when
	// PACKAGE_ENFORCEMENT=0 / manifest unavailable.
	_, pkg, tiered := s.packageForTenant(ctx, userID)
	if tiered && !pkg.AllowsEngine(req.Engine) {
		return RegisterResult{}, fmt.Errorf("%w: %q (package allows %v)", ErrEngineNotInPackage, req.Engine, pkg.Engines)
	}
	plan, err := s.sealCredential(ctx, req, tiered, pkg)
	if err != nil {
		return RegisterResult{}, err
	}
	var out RegisterResult
	err = s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		if err := s.checkMountQuota(ctx, tx, userID, tiered, pkg); err != nil {
			return err
		}
		return insertMount(ctx, tx, userID, req, isolation, plan, &out)
	})
	return out, mapRegisterError(err)
}

// mountPlan captures the resolved credential shape for an insert: usingRef and
// usingCMEK select the column layout; payload/cmekWrap/cmekKeyID carry the
// sealed material (empty for a cred-ref mount).
type mountPlan struct {
	usingRef  bool
	usingCMEK bool
	payload   EncryptedPayload
	cmekWrap  []byte
	cmekKeyID string
}

// sealCredential resolves the credential mode and seals an inline DSN. CMEK /
// BYOK (D4.8): an inline mount is sealed via the external KMS envelope when CMEK
// is enabled AND a key id is in play (request kms_key_id, else the env default);
// cred-ref mounts NEVER use CMEK. When CMEK is disabled / no key id resolves the
// EXACT existing inline path runs (byte-parity baseline). The S2 max-tier check
// runs here, AFTER the CMEK decision, because a CMEK-sealed DSN is a valid
// non-plaintext-at-rest path that a max-tier tenant may use.
func (s *Service) sealCredential(ctx context.Context, req RegisterDatabaseRequest, tiered bool, pkg packages.Package) (mountPlan, error) {
	p := mountPlan{usingRef: req.CredentialRef.set(), cmekKeyID: req.KMSKeyID}
	if p.cmekKeyID == "" {
		p.cmekKeyID = s.cmekDefaultKeyID
	}
	p.usingCMEK = s.cmekEnabled && !p.usingRef && p.cmekKeyID != ""
	if tiered && !p.usingRef && !p.usingCMEK && pkg.SecurityMode == "max" {
		return mountPlan{}, ErrPlaintextDsnForbidden
	}
	switch {
	case p.usingCMEK:
		return s.sealCMEK(ctx, req, p)
	case !p.usingRef:
		payload, err := s.enc.Encrypt(req.ConnectionString)
		if err != nil {
			return mountPlan{}, err
		}
		p.payload = payload
	}
	return p, nil
}

// sealCMEK envelope-seals the inline DSN: a fresh DEK encrypts it (reusing
// connection_enc/iv/tag) and the KMS wraps the DEK. No scrypt salt (CMEK has no
// KDF), so connection_salt stays NULL.
func (s *Service) sealCMEK(ctx context.Context, req RegisterDatabaseRequest, p mountPlan) (mountPlan, error) {
	wrapped, iv, ct, sErr := cmek.Seal(ctx, s.kms, p.cmekKeyID, []byte(req.ConnectionString))
	if sErr != nil {
		return mountPlan{}, fmt.Errorf("cmek seal: %w", sErr)
	}
	enc, tag, spErr := cmek.SplitCiphertext(ct)
	if spErr != nil {
		return mountPlan{}, spErr
	}
	p.payload = EncryptedPayload{Encrypted: enc, IV: iv, Tag: tag}
	p.cmekWrap = wrapped
	return p, nil
}

// checkMountQuota enforces the package max_mounts cap INSIDE the tx so the count
// is consistent with the insert (no TOCTOU under concurrent registrations).
func (s *Service) checkMountQuota(ctx context.Context, tx pgx.Tx, userID string, tiered bool, pkg packages.Package) error {
	if !tiered || pkg.PoolPolicy.MaxMounts <= 0 {
		return nil
	}
	var count int
	if err := tx.QueryRow(ctx,
		`SELECT count(*) FROM public.tenant_databases WHERE tenant_id = $1`, userID).Scan(&count); err != nil {
		return err
	}
	if count >= pkg.PoolPolicy.MaxMounts {
		return ErrMountQuotaExceeded
	}
	return nil
}
