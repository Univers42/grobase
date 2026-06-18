package audit

import (
	"context"
	"encoding/json"
	"hash/fnv"
	"time"

	"github.com/jackc/pgx/v5"
)

// readTip reads the tenant's chain tip (max seq + its hash) under the held
// advisory lock — ("",0) at genesis. It is step 2 of the Append transaction.
func readTip(ctx context.Context, tx pgx.Tx, tenantID string) (int64, string, error) {
	var prevSeq int64
	var prevHash string
	row := tx.QueryRow(ctx,
		`SELECT COALESCE(MAX(seq),0),
		        COALESCE((SELECT hash FROM public.tenant_audit_log
		                   WHERE tenant_id = $1 ORDER BY seq DESC LIMIT 1), '')
		   FROM public.tenant_audit_log WHERE tenant_id = $1`, tenantID)
	if err := row.Scan(&prevSeq, &prevHash); err != nil {
		return 0, "", err
	}
	return prevSeq, prevHash, nil
}

// sealLink builds the next Event from the tip with the canonical chain rule —
// step 3 of the Append transaction (the SAME ComputeHash the verifier uses).
func sealLink(in AppendInput, prevSeq int64, prevHash string) Event {
	ev := Event{
		TenantID: in.TenantID,
		Seq:      prevSeq + 1,
		Ts:       time.Now().UTC(),
		Actor:    in.Actor,
		Action:   in.Action,
		Target:   in.Target,
		Payload:  normalizePayload(in.Payload),
		PrevHash: prevHash,
	}
	ev.Hash = ComputeHash(ev)
	return ev
}

// insertEvent INSERTs the sealed link and assigns its id — step 4 of Append.
func insertEvent(ctx context.Context, tx pgx.Tx, ev *Event) error {
	return tx.QueryRow(
		ctx, `
		INSERT INTO public.tenant_audit_log
		  (tenant_id, seq, ts, actor, action, target, payload, prev_hash, hash)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		RETURNING id`,
		ev.TenantID, ev.Seq, ev.Ts, ev.Actor, ev.Action, ev.Target, []byte(ev.Payload), ev.PrevHash, ev.Hash,
	).Scan(&ev.ID)
}

// normalizePayload guarantees a non-nil, valid JSON payload ('{}' default),
// mirroring the table's DEFAULT '{}'::jsonb — so the chain never hashes a NULL.
func normalizePayload(p []byte) json.RawMessage {
	if len(p) == 0 {
		return json.RawMessage(`{}`)
	}
	return json.RawMessage(p)
}

// lockKey hashes a tenant id to a stable signed 64-bit pg_advisory lock key, so
// appends serialize per tenant (different tenants get different keys → no
// cross-tenant contention). FNV-1a is deterministic and fast; the value is
// reinterpreted as int64 (pg_advisory_xact_lock(bigint)) — wrapping to a signed
// bigint, where a collision only costs serialization, never correctness.
func lockKey(tenantID string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(tenantID))
	return int64(h.Sum64())
}
