/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   register_store.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:38:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:38:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// mountInsert is the row being inserted: the tx, the owning tenant, the request,
// the resolved isolation, the sealed credential plan, and the result sink. Shared
// 1:1 across all four insert helpers (insertCredRef ignores the plan field).
type mountInsert struct {
	tx        pgx.Tx
	userID    string
	req       RegisterDatabaseRequest
	isolation string
	p         mountPlan
	out       *RegisterResult
}

// insertMount writes the row in the column layout the credential mode dictates
// (cred-ref / CMEK-envelope / inline-master-key) and scans the result into out.
func insertMount(ctx context.Context, m mountInsert) error {
	switch {
	case m.p.usingRef:
		return insertCredRef(ctx, m)
	case m.p.usingCMEK:
		return insertCMEK(ctx, m)
	default:
		return insertInline(ctx, m)
	}
}

// sharedResourcesValue marshals the request's optional shared-table list to a
// JSONB value for INSERT, or nil (SQL NULL) when none is set — so a mount
// registered without shared_resources stores NULL = byte-parity with today.
func sharedResourcesValue(names []string) (any, error) {
	if len(names) == 0 {
		return nil, nil
	}
	b, err := json.Marshal(names)
	if err != nil {
		return nil, err
	}
	return b, nil
}

// insertCredRef writes a cred-ref row: NULL inline-encrypted columns, populated
// cred_*. version may be empty (NULL) — the data plane treats absent as latest.
func insertCredRef(ctx context.Context, m mountInsert) error {
	var version any
	if m.req.CredentialRef.Version != "" {
		version = m.req.CredentialRef.Version
	}
	shared, err := sharedResourcesValue(m.req.SharedResources)
	if err != nil {
		return err
	}
	row := m.tx.QueryRow(
		ctx,
		`INSERT INTO public.tenant_databases
		   (tenant_id, engine, name, cred_provider, cred_reference, cred_version, isolation, shared_resources, read_scoped)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		 RETURNING id, engine, name, created_at::text`,
		m.userID, m.req.Engine, m.req.Name,
		m.req.CredentialRef.Provider, m.req.CredentialRef.Reference, version, m.isolation, shared, m.req.ReadScoped,
	)
	return row.Scan(&m.out.ID, &m.out.Engine, &m.out.Name, &m.out.CreatedAt)
}

// insertCMEK writes a CMEK-envelope row: DEK-encrypted DSN in enc/iv/tag (NO
// salt — no KDF) + the KMS-wrapped DEK + the KMS key id. cred_* stay NULL. The
// 3-way DB check (migration 061 / EnsureSchema) enforces this exact shape.
func insertCMEK(ctx context.Context, m mountInsert) error {
	shared, err := sharedResourcesValue(m.req.SharedResources)
	if err != nil {
		return err
	}
	row := m.tx.QueryRow(
		ctx,
		`INSERT INTO public.tenant_databases
		   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag,
		    cmek_wrapped_dek, cmek_kms_key_id, isolation, shared_resources, read_scoped)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
		 RETURNING id, engine, name, created_at::text`,
		m.userID, m.req.Engine, m.req.Name,
		m.p.payload.Encrypted, m.p.payload.IV, m.p.payload.Tag, m.p.cmekWrap, m.p.cmekKeyID, m.isolation, shared, m.req.ReadScoped,
	)
	return row.Scan(&m.out.ID, &m.out.Engine, &m.out.Name, &m.out.CreatedAt)
}

// insertInline writes the today's-path inline-master-key row (enc/iv/tag/salt).
func insertInline(ctx context.Context, m mountInsert) error {
	shared, err := sharedResourcesValue(m.req.SharedResources)
	if err != nil {
		return err
	}
	row := m.tx.QueryRow(
		ctx,
		`INSERT INTO public.tenant_databases
		   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, connection_salt, isolation, shared_resources, read_scoped)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		 RETURNING id, engine, name, created_at::text`,
		m.userID, m.req.Engine, m.req.Name,
		m.p.payload.Encrypted, m.p.payload.IV, m.p.payload.Tag, m.p.payload.Salt, m.isolation, shared, m.req.ReadScoped,
	)
	return row.Scan(&m.out.ID, &m.out.Engine, &m.out.Name, &m.out.CreatedAt)
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
