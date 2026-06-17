package audit

import (
	"encoding/json"
	"testing"
	"time"
)

// buildChain seals n events into a valid chain the SAME way Service.Append does
// (ComputeHash over running prev_hash), so a test can mutate a stored row and
// assert VerifyChain catches it at exactly that link. This mirrors the live
// append path's hashing, which is what makes the test load-bearing rather than
// circular: tamper any field of any sealed event and the recompute diverges.
func buildChain(t *testing.T, tenant string, n int) []Event {
	t.Helper()
	events := make([]Event, 0, n)
	prev := ""
	base := time.Date(2026, 6, 14, 12, 0, 0, 0, time.UTC)
	for i := 1; i <= n; i++ {
		e := Event{
			TenantID: tenant,
			Seq:      int64(i),
			Ts:       base.Add(time.Duration(i) * time.Second),
			Actor:    "api-key:actor-" + itoa(i),
			Action:   "key.issue",
			Target:   "target-" + itoa(i),
			Payload:  json.RawMessage(`{"n":` + itoa(i) + `}`),
			PrevHash: prev,
		}
		e.Hash = ComputeHash(e.PrevHash, e.TenantID, e.Seq, e.Ts, e.Actor, e.Action, e.Target, e.Payload)
		events = append(events, e)
		prev = e.Hash
	}
	return events
}

func itoa(i int) string { return string(rune('0'+i%10)) } // single-digit ok for tests

func TestVerifyChain_Intact(t *testing.T) {
	events := buildChain(t, "tnt-A", 5)
	res := VerifyChain("tnt-A", events)
	if !res.Intact {
		t.Fatalf("freshly sealed chain must be intact, got broken_seq=%d reason=%s", res.BrokenSeq, res.Reason)
	}
	if res.Count != 5 {
		t.Fatalf("expected count=5, got %d", res.Count)
	}
}

func TestVerifyChain_Empty(t *testing.T) {
	res := VerifyChain("tnt-A", nil)
	if !res.Intact || res.Count != 0 {
		t.Fatalf("empty chain must verify intact with count 0, got %+v", res)
	}
}

// THE load-bearing test: directly mutate a STORED row's payload (as a tamperer
// editing the DB would) WITHOUT recomputing its hash. Verify must report the
// chain BROKEN at exactly that link with reason=hash_mismatch. A vacuous verifier
// that always says intact fails this test.
func TestVerifyChain_TamperedPayload(t *testing.T) {
	events := buildChain(t, "tnt-A", 5)
	events[2].Payload = json.RawMessage(`{"n":999}`) // tamper link seq=3, leave its hash stale
	res := VerifyChain("tnt-A", events)
	if res.Intact {
		t.Fatal("tampered payload must break the chain — vacuous verify rejected")
	}
	if res.BrokenSeq != 3 {
		t.Fatalf("expected break at seq=3 (the tampered link), got broken_seq=%d reason=%s", res.BrokenSeq, res.Reason)
	}
	if res.Reason != "hash_mismatch" {
		t.Fatalf("expected reason=hash_mismatch, got %s", res.Reason)
	}
}

// Mutating any OTHER hashed field (actor) must also break at that link.
func TestVerifyChain_TamperedActor(t *testing.T) {
	events := buildChain(t, "tnt-A", 4)
	events[1].Actor = "api-key:attacker"
	res := VerifyChain("tnt-A", events)
	if res.Intact || res.BrokenSeq != 2 || res.Reason != "hash_mismatch" {
		t.Fatalf("tampered actor must break at seq=2 hash_mismatch, got %+v", res)
	}
}

// Deleting a middle row (seq hole) must be detected — tamper-evidence covers
// removal, not just edits. After deleting seq=3, the row that was seq=4 now sits
// where seq=3 is expected → seq_gap.
func TestVerifyChain_DeletedRow(t *testing.T) {
	events := buildChain(t, "tnt-A", 5)
	tampered := append([]Event{}, events[:2]...)   // seq 1,2
	tampered = append(tampered, events[3:]...)      // seq 4,5 (3 removed)
	res := VerifyChain("tnt-A", tampered)
	if res.Intact {
		t.Fatal("deleting a row must break the chain")
	}
	if res.BrokenSeq != 4 || res.Reason != "seq_gap" {
		t.Fatalf("expected seq_gap at seq=4, got broken_seq=%d reason=%s", res.BrokenSeq, res.Reason)
	}
}

// Re-pointing prev_hash (splicing) must be caught as prev_hash_mismatch.
func TestVerifyChain_BrokenPrevHash(t *testing.T) {
	events := buildChain(t, "tnt-A", 4)
	events[2].PrevHash = "deadbeef" // splice link 3 off the chain
	// NOTE: we do NOT recompute events[2].Hash — a real tamperer who only edits
	// prev_hash leaves the stored hash stale, so this surfaces as the prev
	// linkage break (checked before the hash recompute) at seq=3.
	res := VerifyChain("tnt-A", events)
	if res.Intact || res.BrokenSeq != 3 || res.Reason != "prev_hash_mismatch" {
		t.Fatalf("spliced prev_hash must break at seq=3 prev_hash_mismatch, got %+v", res)
	}
}

// canonicalJSON makes key order irrelevant: two payloads equal up to key order
// must hash identically, so a verifier never false-positives on a re-serialized
// (but unchanged) payload.
func TestComputeHash_PayloadKeyOrderStable(t *testing.T) {
	ts := time.Date(2026, 6, 14, 12, 0, 0, 0, time.UTC)
	h1 := ComputeHash("", "t", 1, ts, "a", "act", "tgt", []byte(`{"x":1,"y":2}`))
	h2 := ComputeHash("", "t", 1, ts, "a", "act", "tgt", []byte(`{"y":2,"x":1}`))
	if h1 != h2 {
		t.Fatalf("key-order must not change the hash: %s != %s", h1, h2)
	}
	// but a real value change MUST change the hash.
	h3 := ComputeHash("", "t", 1, ts, "a", "act", "tgt", []byte(`{"x":1,"y":3}`))
	if h1 == h3 {
		t.Fatal("a payload value change must change the hash")
	}
}

// Length-prefixing must make the canonical form injective: shifting a byte
// between adjacent fields must change the hash (no "actor=ab,action=c" vs
// "actor=a,action=bc" collision).
func TestComputeHash_FieldsInjective(t *testing.T) {
	ts := time.Date(2026, 6, 14, 12, 0, 0, 0, time.UTC)
	h1 := ComputeHash("", "t", 1, ts, "ab", "c", "", []byte(`{}`))
	h2 := ComputeHash("", "t", 1, ts, "a", "bc", "", []byte(`{}`))
	if h1 == h2 {
		t.Fatal("field boundaries must be injective (length-prefix) — got a collision")
	}
}
