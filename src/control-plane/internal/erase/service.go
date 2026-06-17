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
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
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
		s.markFailed(ctx, receiptID, derr)
		return Receipt{ID: receiptID, TenantID: tenantID, Status: "failed"}, derr
	}
	return s.finishErase(ctx, receiptID, tenantID, requestedBy, scope, rows, keys)
}

// finishErase runs the post-destruction steps once data is provably gone: flush
// the key-verify cache, soft-mark the tenant deleted, seal the D3 receipt, and
// finalize the erasure_receipts ledger row into the completed Receipt.
func (s *Service) finishErase(ctx context.Context, receiptID, tenantID, requestedBy, scope string, rows, keys int64) (Receipt, error) {
	// The DB key rows are gone — drop the verify fast-path cache so the credential
	// stops authenticating immediately (otherwise it lingers until the cache TTL).
	if s.flushKeyCache != nil {
		s.flushKeyCache()
	}
	s.markTenantDeleted(ctx, tenantID)
	// Seal the tamper-evident D3 receipt. This is the proof the erase HAPPENED —
	// it lives on the per-tenant hash chain, which the auditor can verify even
	// after every other trace of the tenant is gone.
	auditSeq := s.sealReceipt(ctx, tenantID, requestedBy, scope, rows, keys)
	if err := s.finalizeReceipt(ctx, receiptID, rows, keys, auditSeq); err != nil {
		return Receipt{}, err
	}
	return Receipt{
		ID: receiptID, TenantID: tenantID, RequestedBy: requestedBy, Scope: scope,
		RowsPurged: rows, KeysRevoked: keys, AuditSeq: auditSeq, Status: "completed",
	}, nil
}
