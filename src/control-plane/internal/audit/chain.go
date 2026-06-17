// Package audit (Track-D D3) is the control-plane TAMPER-EVIDENT, tenant-facing
// audit trail. It maintains a per-tenant HASH CHAIN over append-only audit
// events and exposes a tenant-facing query / export / verify API.
//
// THE CHAIN (engine-agnostic by construction):
//
//	hash_n = sha256( prev_hash || canonical(event_n) )
//	prev_hash_1 = ""                       (genesis: first event for a tenant)
//	prev_hash_n = hash_(n-1)               (n > 1)
//
// canonical(event) is a deterministic, field-ordered serialization of the
// SEMANTIC columns (tenant_id, seq, ts, actor, action, target, payload). It is
// computed IN GO over the stored rows — the chain does NOT depend on any DB
// hashing function, so the identical verify runs over rows from any data engine
// (the kernel's engine-agnostic rule). Any post-hoc edit of a stored field, a
// deleted row (seq hole), or a re-ordered seq changes some canonical(event) or
// breaks prev linkage, so the recomputed hash diverges at exactly that link —
// that is the whole point, and the gate's load-bearing REJECT proves it.
//
// FLAG-GATED OFF = PARITY: this package is only reachable when
// TENANT_AUDIT_ENABLED is truthy (cmd/tenant-control mounts the routes only
// then). When OFF, nothing here runs and no audit row is ever written — the
// control plane is byte-identical to today.
package audit

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Event is one link in a tenant's audit chain — the canonical form the hash is
// computed over PLUS the chain fields. The query/export APIs marshal this; the
// verifier recomputes Hash from PrevHash + the semantic fields.
type Event struct {
	ID       string          `json:"id"`
	TenantID string          `json:"tenant_id"`
	Seq      int64           `json:"seq"`
	Ts       time.Time       `json:"ts"`
	Actor    string          `json:"actor"`
	Action   string          `json:"action"`
	Target   string          `json:"target"`
	Payload  json.RawMessage `json:"payload"`
	PrevHash string          `json:"prev_hash"`
	Hash     string          `json:"hash"`
}

// canonicalBytes is the deterministic serialization the chain hashes over. It is
// a length-prefixed (LEN ':' VALUE '\n') framing of the semantic fields in a
// FIXED order. Length-prefixing makes the encoding injective — no choice of
// field values can produce the same byte stream as a different tuple (so an
// attacker cannot "shift" bytes between actor/action/target to forge a row that
// rehashes to the stored hash). Timestamps are RFC3339Nano in UTC so the same
// instant always serializes identically regardless of the DB's session zone.
//
// FROZEN: changing this function changes every hash. It must stay byte-stable
// across builds — that is why it is hand-rolled and length-prefixed rather than
// "json.Marshal a struct" (Go's map/json ordering and escaping are not a
// contract). payload is canonicalized via canonicalJSON so two semantically
// equal JSON objects (key order aside) hash identically.
func canonicalBytes(tenantID string, seq int64, ts time.Time, actor, action, target string, payload []byte) []byte {
	var b []byte
	add := func(s string) {
		b = append(b, []byte(strconv.Itoa(len(s)))...)
		b = append(b, ':')
		b = append(b, []byte(s)...)
		b = append(b, '\n')
	}
	add(tenantID)
	add(strconv.FormatInt(seq, 10))
	// Truncate to MICROSECOND: postgres timestamptz stores µs precision, so a
	// nanosecond Go time hashes differently at seal vs after the DB round-trip at
	// verify. pgx floors ns->µs, matching time.Truncate, so seal == verify.
	add(ts.UTC().Truncate(time.Microsecond).Format(time.RFC3339Nano))
	add(actor)
	add(action)
	add(target)
	add(string(shared.CanonicalJSON(payload)))
	return b
}

// ComputeHash returns the lower-hex sha256 of (prevHash || canonical(fields)).
// This is THE chain rule — append uses it to seal a new link; verify uses it to
// recompute and compare. Identical inputs MUST produce an identical hash on any
// machine (no map iteration, no locale, no DB function involved).
func ComputeHash(prevHash, tenantID string, seq int64, ts time.Time, actor, action, target string, payload []byte) string {
	h := sha256.New()
	h.Write([]byte(prevHash))
	h.Write(canonicalBytes(tenantID, seq, ts, actor, action, target, payload))
	return hex.EncodeToString(h.Sum(nil))
}

// recompute hashes one Event using its stored PrevHash + semantic fields. The
// verifier compares this against the stored Hash.
func recompute(e Event) string {
	return ComputeHash(e.PrevHash, e.TenantID, e.Seq, e.Ts, e.Actor, e.Action, e.Target, e.Payload)
}
