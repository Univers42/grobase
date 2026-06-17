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
)

// Event is one link in a tenant's audit chain — the canonical form the hash is
// computed over PLUS the chain fields. The query/export APIs marshal this; the
// verifier recomputes Hash from PrevHash + the semantic fields.
type Event struct {
	ID        string          `json:"id"`
	TenantID  string          `json:"tenant_id"`
	Seq       int64           `json:"seq"`
	Ts        time.Time       `json:"ts"`
	Actor     string          `json:"actor"`
	Action    string          `json:"action"`
	Target    string          `json:"target"`
	Payload   json.RawMessage `json:"payload"`
	PrevHash  string          `json:"prev_hash"`
	Hash      string          `json:"hash"`
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
	add(string(canonicalJSON(payload)))
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

// canonicalJSON re-serializes a JSON value with object keys sorted recursively,
// so two semantically equal payloads hash to the same bytes regardless of key
// order or insignificant whitespace. Invalid/empty JSON canonicalizes to "{}"
// (the table default) so a NULL/garbage payload never panics the chain.
func canonicalJSON(raw []byte) []byte {
	if len(raw) == 0 {
		return []byte("{}")
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return []byte("{}")
	}
	// json.Marshal sorts map[string]any keys, and our decoded objects are
	// map[string]any, so a re-marshal yields a key-sorted canonical form.
	out, err := json.Marshal(sortValue(v))
	if err != nil {
		return []byte("{}")
	}
	return out
}

// sortValue walks a decoded JSON value. json.Marshal already emits map keys in
// sorted order, so the walk just needs to recurse to normalize nested objects
// inside arrays (Marshal handles maps directly, but we recurse to be explicit
// and to keep the canonical form stable even if the encoder changes).
func sortValue(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, val := range t {
			out[k] = sortValue(val)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, val := range t {
			out[i] = sortValue(val)
		}
		return out
	default:
		return v
	}
}

// VerifyResult is the outcome of a chain verification for one tenant.
type VerifyResult struct {
	TenantID string `json:"tenant_id"`
	Count    int    `json:"count"`           // events examined
	Intact   bool   `json:"intact"`          // true iff every link recomputes + links correctly
	// BrokenSeq is the seq of the FIRST broken link (0 when intact). Reason
	// names WHY (hash_mismatch | prev_hash_mismatch | seq_gap). FromHash/ToHash
	// give the recomputed-vs-stored hashes at the break for forensics.
	BrokenSeq    int64  `json:"broken_seq,omitempty"`
	Reason       string `json:"reason,omitempty"`
	ExpectedHash string `json:"expected_hash,omitempty"` // recomputed
	StoredHash   string `json:"stored_hash,omitempty"`   // what the row claims
}

// VerifyChain recomputes a tenant's chain from an ordered (seq ASC) slice of
// events and reports the FIRST broken link. It is PURE — no DB, no IO — so the
// unit test can prove tamper detection deterministically (mutate one event's
// payload/actor/hash and assert BrokenSeq == that event's seq).
//
// A link n is intact iff ALL of:
//   - prev_hash linkage: events[0].PrevHash == "" (genesis) and
//     events[i].PrevHash == events[i-1].Hash for i>0.
//   - seq contiguity:    events[i].Seq == events[i-1].Seq + 1 (no hole / reorder),
//     and events[0].Seq == 1.
//   - hash integrity:    events[i].Hash == recompute(events[i]).
//
// The FIRST i that fails any of these is the broken link. Verifying over a
// per-tenant-scoped, seq-ASC query is the caller's responsibility (the SQL binds
// tenant_id and ORDER BY seq) — this function trusts the slice is that scope.
func VerifyChain(tenantID string, events []Event) VerifyResult {
	res := VerifyResult{TenantID: tenantID, Count: len(events), Intact: true}
	prev := "" // genesis prev_hash
	var prevSeq int64
	for i, e := range events {
		// seq contiguity: first must be 1, each subsequent +1.
		wantSeq := int64(i + 1)
		if i == 0 {
			wantSeq = 1
		} else {
			wantSeq = prevSeq + 1
		}
		if e.Seq != wantSeq {
			return broken(res, e.Seq, "seq_gap", "", "")
		}
		// prev_hash linkage to the previous stored hash.
		if e.PrevHash != prev {
			return broken(res, e.Seq, "prev_hash_mismatch", prev, e.PrevHash)
		}
		// hash integrity: recompute from THIS row's fields + its claimed prev.
		want := recompute(e)
		if want != e.Hash {
			return broken(res, e.Seq, "hash_mismatch", want, e.Hash)
		}
		prev = e.Hash
		prevSeq = e.Seq
	}
	return res
}

// broken stamps the first-break fields onto the result and returns it.
func broken(res VerifyResult, seq int64, reason, expected, stored string) VerifyResult {
	res.Intact = false
	res.BrokenSeq = seq
	res.Reason = reason
	res.ExpectedHash = expected
	res.StoredHash = stored
	return res
}
