package audit

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// adb is the minimal Postgres surface the service needs. *pg.Postgres
// satisfies it (the audit service runs as the BYPASSRLS control-plane role); a
// fake satisfies it in unit tests so the append + read contracts are provable
// without a live database. Append needs a transaction for the read-prev /
// write-link atomicity, so we expose Begin too.
type adb interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Begin(ctx context.Context) (pgx.Tx, error)
}

// errEmptyTenant / errEmptyAction guard the append contract — an audit row with
// no tenant or no action verb is meaningless and would poison the chain order.
var (
	errEmptyTenant = errors.New("audit: tenant_id required")
	errEmptyAction = errors.New("audit: action required")
)

// Service appends to and reads the per-tenant tamper-evident audit chain. It is
// the durable twin of the metering store: one idempotent-ish writer + scoped
// readers, all parameterized on tenant_id.
type Service struct {
	db adb
}

// NewService wraps the privileged Postgres handle.
func NewService(db adb) *Service { return &Service{db: db} }

// AppendInput is one event to seal into a tenant's chain.
type AppendInput struct {
	TenantID string
	Actor    string
	Action   string
	Target   string
	Payload  json.RawMessage
}

// Append seals a new link onto the tenant's chain INSIDE A TRANSACTION:
//
//  1. take a per-TENANT transaction advisory lock (pg_advisory_xact_lock) so two
//     concurrent appends for the SAME tenant serialize — without it, both could
//     read the same prev_hash/seq and fork the chain. The lock key is a stable
//     64-bit hash of the tenant id, so different tenants never contend.
//  2. read the tip (max seq + its hash) for this tenant.
//  3. compute seq = tip.seq + 1, prev_hash = tip.hash (or "" at genesis),
//     hash = sha256(prev_hash || canonical(row)) — the SAME ComputeHash the
//     verifier uses, so an appended chain always verifies intact.
//  4. INSERT the row; commit.
//
// The UNIQUE(tenant_id, seq) constraint is the final backstop: even if two
// appends somehow raced the lock, the second INSERT would fail rather than fork.
func (s *Service) Append(ctx context.Context, in AppendInput) (Event, error) {
	if err := validateAppend(in); err != nil {
		return Event{}, err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Event{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	// serialize appends for THIS tenant only, then read tip / seal / insert.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, lockKey(in.TenantID)); err != nil {
		return Event{}, err
	}
	prevSeq, prevHash, err := readTip(ctx, tx, in.TenantID)
	if err != nil {
		return Event{}, err
	}
	ev := sealLink(in, prevSeq, prevHash)
	if err := insertEvent(ctx, tx, &ev); err != nil {
		return Event{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Event{}, err
	}
	return ev, nil
}

// validateAppend guards the append contract: a non-blank tenant and action.
func validateAppend(in AppendInput) error {
	if strings.TrimSpace(in.TenantID) == "" {
		return errEmptyTenant
	}
	if strings.TrimSpace(in.Action) == "" {
		return errEmptyAction
	}
	return nil
}

// listSQL reads one tenant's events in chain order (seq ASC) over an optional
// [from,to) time window with a bounded limit. tenant_id is ALWAYS bound (the
// cross-tenant wall, atop RLS) and ORDER BY seq is the canonical chain order the
// verifier walks.
const listSQL = `
SELECT id, tenant_id, seq, ts, actor, action, target, payload, prev_hash, hash
  FROM public.tenant_audit_log
 WHERE tenant_id = $1
   AND ($2::timestamptz IS NULL OR ts >= $2)
   AND ($3::timestamptz IS NULL OR ts <  $3)
 ORDER BY seq ASC
 LIMIT $4`

// List returns a tenant's events (seq ASC) for the query/export/verify paths.
// limit<=0 falls back to a safe default cap so a huge chain never OOMs a read.
func (s *Service) List(ctx context.Context, tenantID string, from, to time.Time, limit int) ([]Event, error) {
	if limit <= 0 || limit > maxListLimit {
		limit = maxListLimit
	}
	rows, err := s.db.AdminQuery(ctx, listSQL, tenantID, pg.NullableTime(from), pg.NullableTime(to), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Event, 0)
	for rows.Next() {
		var e Event
		var payload []byte
		if err := rows.Scan(&e.ID, &e.TenantID, &e.Seq, &e.Ts, &e.Actor,
			&e.Action, &e.Target, &payload, &e.PrevHash, &e.Hash); err != nil {
			return nil, err
		}
		e.Payload = normalizePayload(payload)
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// Verify reads a tenant's full chain (capped) and recomputes it via VerifyChain.
// Because List binds tenant_id and orders by seq, the slice handed to the pure
// verifier is exactly the tenant-scoped chain — a tenant can never verify
// another tenant's events (it can only ASK for its own id at the edge, and the
// SQL re-binds it here).
func (s *Service) Verify(ctx context.Context, tenantID string) (VerifyResult, error) {
	events, err := s.List(ctx, tenantID, time.Time{}, time.Time{}, maxListLimit)
	if err != nil {
		return VerifyResult{}, err
	}
	return VerifyChain(tenantID, events), nil
}

const maxListLimit = 100_000
