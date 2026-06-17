// Package erase (Track-D D4.4) is the control-plane HARD-ERASE / tenant teardown.
// Today a teardown is SOFT-DELETE only (tenants.status='deleted'; the rows stay,
// recoverable). This package adds a PROVABLE destruction of one tenant's data,
// scoped so erasing tenant A can NEVER touch tenant B, and writes a
// tamper-evident D3 audit receipt that survives the data going away PLUS an
// erasure_receipts ledger row (migration 048) recording the purge.
//
// WHAT "PROVABLE DESTRUCTION" MEANS PER ISOLATION MODEL:
//
//	schema_per_tenant  => DROP SCHEMA <tenant_schema> CASCADE — the schema and
//	                      every object in it ceases to exist. The pre-drop row
//	                      total across the schema's BASE TABLEs is counted first
//	                      (so rows_purged is honest) then the schema is dropped.
//	shared_rls         => DELETE FROM each shared data table WHERE tenant_id
//	                      matches. NEVER a TRUNCATE — that would wipe every
//	                      tenant's rows in a shared table. Only the caller
//	                      tenant's rows are removed; every other tenant's rows are
//	                      untouched by construction (the WHERE binds tenant_id).
//
// API keys: every API key for the tenant is revoked AND deleted, so no
// credential authenticates after the erase (the load-bearing "the key no longer
// works" property the gate asserts).
//
// Storage objects (external object store): BEST-EFFORT + DOCUMENTED. The
// control-plane DB has no authority over an external object store; the erase
// records the intent in the receipt's payload (storage_scope) so a downstream
// reaper / the operator completes physical object deletion. Postgres-resident
// data IS provably destroyed here.
//
// FLAG-GATED OFF = PARITY: this package is only reachable when HARD_ERASE_ENABLED
// is truthy (cmd/tenant-control mounts the route only then). When OFF, nothing
// here runs, no erasure_receipts row is ever written, and no destruction ever
// occurs — the control plane is byte-identical to today's soft-delete-only
// baseline.
package erase

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
	"github.com/jackc/pgx/v5"
)

// ErrUnsupportedScope is returned when a tenant's isolation model is not one of
// the erase-supported models (schema_per_tenant, shared_rls). db_per_tenant and
// tenant_owned are DEFERRED (D4.4b): a db_per_tenant erase is a DROP DATABASE on
// a resolved DSN, and tenant_owned is an external DB the platform must not drop.
// The handler maps it to 400 "isolation not supported for hard-erase (deferred)".
var ErrUnsupportedScope = errors.New("isolation not supported for hard-erase (deferred)")

// ErrNoMount is returned when the tenant has no registered mount to erase.
var ErrNoMount = errors.New("tenant has no registered data mount")

// Service performs a hard-erase over the shared control-plane Postgres. It
// destroys the tenant's Postgres-resident data, revokes+deletes its API keys,
// and writes both a D3 audit receipt and an erasure_receipts ledger row.
type Service struct {
	db    *shared.Postgres
	audit *audit.Service // D3 — seals the tamper-evident erase receipt onto the chain
	log   *slog.Logger
	// flushKeyCache invalidates the control-plane key-verify cache after the keys
	// are deleted, so an erased tenant's credential stops authenticating at once
	// (not after the cache TTL). Optional; nil = nothing to flush.
	flushKeyCache func()
}

// NewService wires the privileged Postgres handle + the D3 audit service. The
// audit service is REQUIRED (the erase receipt is the whole point); main.go
// constructs it the same way the D3 mount does (audit.NewService(db)).
func NewService(db *shared.Postgres, auditSvc *audit.Service, log *slog.Logger) *Service {
	return &Service{db: db, audit: auditSvc, log: log}
}

// SetKeyCacheFlusher wires a callback (the tenants Service's FlushVerifyCache)
// invoked after a successful erase so the destroyed tenant's API key is purged
// from the verify fast-path cache immediately, not only from the DB.
func (s *Service) SetKeyCacheFlusher(f func()) { s.flushKeyCache = f }

// Receipt is the result of a completed hard-erase — the ledger row plus the D3
// audit seq the receipt sealed at.
type Receipt struct {
	ID          string `json:"id"`
	TenantID    string `json:"tenant_id"`
	RequestedBy string `json:"requested_by"`
	Scope       string `json:"scope"`
	RowsPurged  int64  `json:"rows_purged"`
	KeysRevoked int64  `json:"keys_revoked"`
	AuditSeq    int64  `json:"audit_seq"`
	Status      string `json:"status"`
}

// Erase PROVABLY destroys the tenant's Postgres-resident data, then seals the
// proof. Flow (each step bound to tenant_id; A can never reach B):
//
//  1. resolve the tenant's isolation model from public.tenant_databases
//     (tenant_id is a bind param) and guard it (schema_per_tenant | shared_rls).
//  2. INSERT a pending erasure_receipts row.
//  3. DESTROY:
//     schema_per_tenant => count rows then DROP SCHEMA <schema> CASCADE,
//     shared_rls        => DELETE FROM each shared table WHERE tenant_id = $1.
//  4. revoke + delete the tenant's API keys (no credential authenticates after).
//  5. soft-mark the tenant row deleted (the tenant entity is gone too).
//  6. seal a D3 audit receipt (audit.Append) — survives the data going away.
//  7. finalize the erasure_receipts row (completed, rows_purged, audit_seq).
//
// On any destruction failure the receipt flips to 'failed' with the error.
func (s *Service) Erase(ctx context.Context, tenantID, requestedBy string) (Receipt, error) {
	scope, err := s.scopeFor(ctx, tenantID)
	if err != nil {
		return Receipt{}, err
	}
	if scope != "schema_per_tenant" && scope != "shared_rls" {
		return Receipt{}, ErrUnsupportedScope
	}

	receiptID, err := s.insertPending(ctx, tenantID, requestedBy, scope)
	if err != nil {
		return Receipt{}, err
	}

	rows, keys, derr := s.destroy(ctx, tenantID, scope)
	if derr != nil {
		_ = s.db.AdminExec(ctx,
			`UPDATE public.erasure_receipts SET status='failed', error_message=$2 WHERE id=$1`,
			receiptID, derr.Error())
		return Receipt{ID: receiptID, TenantID: tenantID, Status: "failed"}, derr
	}

	// The DB key rows are gone — drop the verify fast-path cache so the credential
	// stops authenticating immediately (otherwise it lingers until the cache TTL).
	if s.flushKeyCache != nil {
		s.flushKeyCache()
	}

	// Soft-mark the tenant entity deleted too (the data is gone; the entity must
	// not keep serving). Best-effort: the data destruction already succeeded, so a
	// status-flip hiccup must not flip the receipt to failed.
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenants SET status='deleted' WHERE slug=$1`, tenantID); err != nil {
		s.log.Warn("erase: mark tenant deleted failed (data already destroyed)", "tenant", tenantID, "err", err)
	}

	// Seal the tamper-evident D3 receipt. This is the proof the erase HAPPENED —
	// it lives on the per-tenant hash chain, which the auditor can verify even
	// after every other trace of the tenant is gone.
	auditSeq := s.sealReceipt(ctx, tenantID, requestedBy, scope, rows, keys)

	if err := s.db.AdminExec(ctx,
		`UPDATE public.erasure_receipts
		    SET status='completed', completed_at=now(),
		        rows_purged=$2, keys_revoked=$3, audit_seq=$4
		  WHERE id=$1`, receiptID, rows, keys, auditSeq); err != nil {
		return Receipt{}, fmt.Errorf("erase: finalize receipt: %w", err)
	}

	return Receipt{
		ID: receiptID, TenantID: tenantID, RequestedBy: requestedBy, Scope: scope,
		RowsPurged: rows, KeysRevoked: keys, AuditSeq: auditSeq, Status: "completed",
	}, nil
}

// scopeFor resolves the tenant's isolation model from public.tenant_databases.
// tenant_id is ALWAYS a bind param (the cross-tenant wall). When the tenant has
// multiple mounts they must share one isolation model for a whole-tenant erase;
// the first row's isolation is authoritative (the MVP scopes whole-tenant erase).
func (s *Service) scopeFor(ctx context.Context, tenantID string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation FROM public.tenant_databases
		  WHERE tenant_id = $1 ORDER BY created_at LIMIT 1`, tenantID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", rerr
		}
		return "", ErrNoMount
	}
	var iso string
	if err := rows.Scan(&iso); err != nil {
		return "", err
	}
	return iso, nil
}

// insertPending records a pending erasure_receipts row and returns its id.
// tenant_id, requested_by and scope are bind params.
func (s *Service) insertPending(ctx context.Context, tenantID, requestedBy, scope string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`INSERT INTO public.erasure_receipts (tenant_id, requested_by, scope, status)
		 VALUES ($1, $2, $3, 'pending')
		 RETURNING id::text`, tenantID, requestedBy, scope)
	if err != nil {
		return "", fmt.Errorf("erase: insert receipt: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", fmt.Errorf("erase: insert receipt: %w", rerr)
		}
		return "", fmt.Errorf("erase: insert receipt returned no id")
	}
	var id string
	if err := rows.Scan(&id); err != nil {
		return "", fmt.Errorf("erase: scan receipt id: %w", err)
	}
	return id, nil
}

// destroy performs the scope-appropriate destruction and revokes the keys,
// returning (rows_purged, keys_revoked). The whole destruction runs in ONE
// transaction so it is all-or-nothing: a mid-erase failure leaves the tenant's
// data intact (no half-erased state) and the receipt flips to 'failed'.
func (s *Service) destroy(ctx context.Context, tenantID, scope string) (int64, int64, error) {
	conn, err := s.db.AcquireConn(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var rows int64
	switch scope {
	case "schema_per_tenant":
		rows, err = dropTenantSchema(ctx, tx, tenants.TenantSchema(tenantID))
	case "shared_rls":
		rows, err = deleteSharedRows(ctx, tx, tenantID)
	default:
		err = ErrUnsupportedScope
	}
	if err != nil {
		return 0, 0, err
	}

	keys, err := revokeKeys(ctx, tx, tenantID)
	if err != nil {
		return 0, 0, err
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, 0, fmt.Errorf("erase: commit destruction: %w", err)
	}
	return rows, keys, nil
}

// sealReceipt appends a D3 audit event recording the erase onto the tenant's
// tamper-evident chain and returns the sealed seq. Best-effort on the seq: the
// destruction already committed, so an audit hiccup must not undo it — but the
// erasure_receipts row still records what happened (audit_seq stays 0 then). The
// receipt payload carries the storage-scope note (object-store deletion is the
// downstream reaper's job; the platform records the intent here).
func (s *Service) sealReceipt(ctx context.Context, tenantID, requestedBy, scope string, rows, keys int64) int64 {
	payload, _ := json.Marshal(map[string]any{
		"scope":         scope,
		"rows_purged":   rows,
		"keys_revoked":  keys,
		"storage_scope": "object-store deletion is best-effort/downstream; postgres data provably destroyed",
	})
	ev, err := s.audit.Append(ctx, audit.AppendInput{
		TenantID: tenantID,
		Actor:    requestedBy,
		Action:   "tenant.erase",
		Target:   tenantID,
		Payload:  payload,
	})
	if err != nil {
		s.log.Warn("erase: audit receipt append failed (data already destroyed)", "tenant", tenantID, "err", err)
		return 0
	}
	return ev.Seq
}

// dropTenantSchema counts the rows across the tenant schema's BASE TABLEs then
// DROPs the schema CASCADE. The schema name comes from the single-source
// tenants.TenantSchema sanitizer (never interpolated user input — it is
// [a-z0-9_]-only and prefixed tenant_), and is double-quoted for the DDL via
// pgx.Identifier.Sanitize. A non-resolvable id (empty schema) is a hard error.
func dropTenantSchema(ctx context.Context, tx pgx.Tx, schema string) (int64, error) {
	if schema == "" {
		return 0, fmt.Errorf("erase: tenant id sanitizes to an empty schema")
	}
	total, err := countSchemaRows(ctx, tx, schema)
	if err != nil {
		return 0, err
	}
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := tx.Exec(ctx, fmt.Sprintf(`DROP SCHEMA IF EXISTS %s CASCADE`, quoted)); err != nil {
		return 0, fmt.Errorf("erase: drop schema %s: %w", quoted, err)
	}
	return total, nil
}

// countSchemaRows sums row counts across every BASE TABLE in the schema (so the
// receipt's rows_purged is an honest pre-drop total). schema is a bind param in
// the catalog query; each per-table COUNT uses a sanitized identifier.
func countSchemaRows(ctx context.Context, tx pgx.Tx, schema string) (int64, error) {
	rows, err := tx.Query(ctx,
		`SELECT table_name FROM information_schema.tables
		  WHERE table_schema = $1 AND table_type = 'BASE TABLE'
		  ORDER BY table_name`, schema)
	if err != nil {
		return 0, fmt.Errorf("erase: enumerate schema tables: %w", err)
	}
	var tables []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			rows.Close()
			return 0, err
		}
		tables = append(tables, t)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	var total int64
	for _, tbl := range tables {
		qualified := pgx.Identifier{schema, tbl}.Sanitize()
		var n int64
		if err := tx.QueryRow(ctx, fmt.Sprintf(`SELECT count(*) FROM %s`, qualified)).Scan(&n); err != nil {
			return 0, fmt.Errorf("erase: count %s: %w", qualified, err)
		}
		total += n
	}
	return total, nil
}

// deleteSharedRows removes ONLY the caller tenant's rows from the shared data
// tables — every table in the public schema that carries a tenant_id column,
// EXCLUDING the control-plane bookkeeping tables (the tenants registry, its keys,
// and the per-tenant ledgers themselves, which the audit/receipt trail relies
// on). NEVER a TRUNCATE: that would wipe every tenant's rows. tenant_id is bound
// per DELETE, so tenant B's rows in the same shared table are untouched.
func deleteSharedRows(ctx context.Context, tx pgx.Tx, tenantID string) (int64, error) {
	rows, err := tx.Query(ctx, `
		SELECT c.table_name
		  FROM information_schema.columns c
		 WHERE c.table_schema = 'public'
		   AND c.column_name = 'tenant_id'
		   AND c.table_name NOT IN (
		         'tenants','tenant_api_keys','tenant_databases','tenant_usage',
		         'tenant_billing','tenant_backups','tenant_audit_log',
		         'erasure_receipts','schema_migrations')
		 ORDER BY c.table_name`)
	if err != nil {
		return 0, fmt.Errorf("erase: enumerate shared tables: %w", err)
	}
	var tables []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			rows.Close()
			return 0, err
		}
		tables = append(tables, t)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	var total int64
	for _, tbl := range tables {
		qualified := pgx.Identifier{"public", tbl}.Sanitize()
		tag, err := tx.Exec(ctx,
			fmt.Sprintf(`DELETE FROM %s WHERE tenant_id = $1`, qualified), tenantID)
		if err != nil {
			return 0, fmt.Errorf("erase: delete from %s: %w", qualified, err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// revokeKeys revokes AND deletes every API key for the tenant so no credential
// authenticates after the erase. tenant_id is the tenant slug carried by the
// /v1/tenants/{id} path; tenant_api_keys.tenant_id is the tenant UUID, so the
// DELETE joins through public.tenants on slug. Returns the count deleted.
func revokeKeys(ctx context.Context, tx pgx.Tx, tenantSlug string) (int64, error) {
	tag, err := tx.Exec(ctx, `
		DELETE FROM public.tenant_api_keys k
		 USING public.tenants t
		 WHERE k.tenant_id = t.id AND t.slug = $1`, tenantSlug)
	if err != nil {
		return 0, fmt.Errorf("erase: delete api keys: %w", err)
	}
	return tag.RowsAffected(), nil
}
