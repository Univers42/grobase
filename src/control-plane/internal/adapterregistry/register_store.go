package adapterregistry

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// insertMount writes the row in the column layout the credential mode dictates
// (cred-ref / CMEK-envelope / inline-master-key) and scans the result into out.
func insertMount(ctx context.Context, tx pgx.Tx, userID string, req RegisterDatabaseRequest, isolation string, p mountPlan, out *RegisterResult) error {
	switch {
	case p.usingRef:
		return insertCredRef(ctx, tx, userID, req, isolation, out)
	case p.usingCMEK:
		return insertCMEK(ctx, tx, userID, req, isolation, p, out)
	default:
		return insertInline(ctx, tx, userID, req, isolation, p, out)
	}
}

// insertCredRef writes a cred-ref row: NULL inline-encrypted columns, populated
// cred_*. version may be empty (NULL) — the data plane treats absent as latest.
func insertCredRef(ctx context.Context, tx pgx.Tx, userID string, req RegisterDatabaseRequest, isolation string, out *RegisterResult) error {
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

// insertCMEK writes a CMEK-envelope row: DEK-encrypted DSN in enc/iv/tag (NO
// salt — no KDF) + the KMS-wrapped DEK + the KMS key id. cred_* stay NULL. The
// 3-way DB check (migration 061 / EnsureSchema) enforces this exact shape.
func insertCMEK(ctx context.Context, tx pgx.Tx, userID string, req RegisterDatabaseRequest, isolation string, p mountPlan, out *RegisterResult) error {
	row := tx.QueryRow(ctx,
		`INSERT INTO public.tenant_databases
		   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag,
		    cmek_wrapped_dek, cmek_kms_key_id, isolation)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		 RETURNING id, engine, name, created_at::text`,
		userID, req.Engine, req.Name,
		p.payload.Encrypted, p.payload.IV, p.payload.Tag, p.cmekWrap, p.cmekKeyID, isolation,
	)
	return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
}

// insertInline writes the today's-path inline-master-key row (enc/iv/tag/salt).
func insertInline(ctx context.Context, tx pgx.Tx, userID string, req RegisterDatabaseRequest, isolation string, p mountPlan, out *RegisterResult) error {
	row := tx.QueryRow(ctx,
		`INSERT INTO public.tenant_databases
		   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, connection_salt, isolation)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		 RETURNING id, engine, name, created_at::text`,
		userID, req.Engine, req.Name,
		p.payload.Encrypted, p.payload.IV, p.payload.Tag, p.payload.Salt, isolation,
	)
	return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
}

// mapRegisterError translates a tx error into the package's sentinel set: the
// quota sentinel passes through, a 23505 unique violation becomes ErrConflict,
// nil stays nil. Byte-identical to the inline error handling it replaced.
func mapRegisterError(err error) error {
	if err == nil || errors.Is(err, ErrMountQuotaExceeded) {
		return err
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return ErrConflict
	}
	return err
}
