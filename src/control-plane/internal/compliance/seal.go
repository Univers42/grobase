// Package compliance (Track-D D4.1) is the control-plane SOC2-LITE EVIDENCE
// COLLECTOR. It snapshots compliance evidence — the CI/gate posture, a platform
// access review, and the git change-management trail — into a durable,
// HASH-SEALED store (migration 051's public.compliance_evidence) and exposes a
// read + verify API.
//
// THE SEAL (engine-agnostic by construction):
//
//	hash = sha256( canonical(section, collected_at, payload) )
//
// canonical(...) is a deterministic, field-ordered serialization computed IN GO
// over the row's semantic fields. It does NOT depend on any DB hashing function,
// so the identical verify runs over rows from any data engine (the kernel's
// engine-agnostic rule). Any post-hoc edit of a stored section, collected_at, or
// payload changes the canonical bytes, so the recomputed hash diverges from the
// stored one at exactly that row — that is the whole point, and the gate's
// load-bearing REJECT proves it by tampering a row and asserting verify catches
// the mismatch.
//
// FLAG-GATED OFF = PARITY: this package is only reachable when
// SOC2_EVIDENCE_ENABLED is truthy (cmd/tenant-control mounts the routes only
// then, and Collect is only called then). When OFF, nothing here runs and no
// compliance row is ever written — the control plane is byte-identical to today.
package compliance

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"time"
)

// Section is the control family one evidence row attests. The collector
// snapshots a fixed set of SOC2-lite / ISO-27001-aligned families. The first
// three (ci, access, change_mgmt) are the original D4.1 sections; the next three
// (gdpr_rights, crypto_posture, backup_posture) broaden the evidenced surface so
// a SOC 2 / ISO 27001 examiner sees the GDPR-rights, cryptography, and
// backup/recovery controls too. Each is OBSERVED from reality — a disabled
// control records enabled:false; none asserts "compliant".
//
// NOTE: the 051 table's section column is free text (no CHECK constraint pins
// the family set), so adding sections needs no migration.
const (
	SectionCI            = "ci"             // CI/gate posture: which mNN gates + CI jobs exist/passed
	SectionAccess        = "access"         // platform access review: role grants
	SectionChangeMgmt    = "change_mgmt"    // git change-management trail: recent commits + authors
	SectionGDPRRights    = "gdpr_rights"    // GDPR data-subject rights: erase (Art.17) + export (Art.20) route posture
	SectionCryptoPosture = "crypto_posture" // cryptography posture: CMEK/BYOK + transport security mode
	SectionBackupPosture = "backup_posture" // backup/recovery posture: PITR + retention config
)

// Sections is the canonical, ordered set a complete snapshot must contain. The
// collector writes exactly these; the read API reports a snapshot complete iff
// all of them are present.
var Sections = []string{
	SectionCI,
	SectionAccess,
	SectionChangeMgmt,
	SectionGDPRRights,
	SectionCryptoPosture,
	SectionBackupPosture,
}

// EvidenceRow is one sealed evidence row — a section's structured payload plus
// the seal fields. The read/verify APIs marshal this; the verifier recomputes
// Hash from Section + CollectedAt + Payload.
type EvidenceRow struct {
	ID          string          `json:"id"`
	SnapshotID  string          `json:"snapshot_id"`
	CollectedAt time.Time       `json:"collected_at"`
	Section     string          `json:"section"`
	Payload     json.RawMessage `json:"payload"`
	Hash        string          `json:"hash"`
}

// canonicalBytes is the deterministic serialization the seal hashes over: a
// length-prefixed (LEN ':' VALUE '\n') framing of the semantic fields in a FIXED
// order. Length-prefixing makes the encoding injective — no choice of field
// values can produce the same byte stream as a different tuple, so an attacker
// cannot "shift" bytes between section/payload to forge a row that rehashes to
// the stored hash. collected_at is RFC3339Nano in UTC truncated to MICROSECONDS
// (postgres timestamptz stores µs; pgx floors ns->µs, so seal == verify after
// the round-trip). payload is canonicalized via canonicalJSON so two
// semantically equal JSON payloads (key order aside) seal identically.
//
// FROZEN: changing this function changes every hash. It must stay byte-stable
// across builds — that is why it is hand-rolled and length-prefixed rather than
// "json.Marshal a struct" (Go's map/json ordering and escaping are not a
// contract).
func canonicalBytes(section string, collectedAt time.Time, payload []byte) []byte {
	var b []byte
	add := func(s string) {
		b = append(b, []byte(strconv.Itoa(len(s)))...)
		b = append(b, ':')
		b = append(b, []byte(s)...)
		b = append(b, '\n')
	}
	add(section)
	add(collectedAt.UTC().Truncate(time.Microsecond).Format(time.RFC3339Nano))
	add(string(canonicalJSON(payload)))
	return b
}

// SealHash returns the lower-hex sha256 of canonical(section, collectedAt,
// payload). This is THE seal rule — Collect uses it to seal a new row; Verify
// uses it to recompute and compare. Identical inputs MUST produce an identical
// hash on any machine (no map iteration, no locale, no DB function involved).
func SealHash(section string, collectedAt time.Time, payload []byte) string {
	h := sha256.New()
	h.Write(canonicalBytes(section, collectedAt, payload))
	return hex.EncodeToString(h.Sum(nil))
}

// recompute hashes one stored row from its semantic fields. The verifier
// compares this against the stored Hash.
func recompute(e EvidenceRow) string {
	return SealHash(e.Section, e.CollectedAt, e.Payload)
}

// canonicalJSON re-serializes a JSON value with object keys sorted recursively,
// so two semantically equal payloads hash to the same bytes regardless of key
// order or insignificant whitespace. Invalid/empty JSON canonicalizes to "{}"
// (the table default) so a NULL/garbage payload never panics the seal.
func canonicalJSON(raw []byte) []byte {
	if len(raw) == 0 {
		return []byte("{}")
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return []byte("{}")
	}
	out, err := json.Marshal(sortValue(v))
	if err != nil {
		return []byte("{}")
	}
	return out
}

// sortValue walks a decoded JSON value. json.Marshal already emits map keys in
// sorted order; the walk recurses so nested objects inside arrays normalize too
// and the canonical form stays stable even if the encoder changes.
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
