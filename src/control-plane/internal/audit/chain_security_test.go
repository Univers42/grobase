/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   chain_security_test.go                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:20 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:21 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package audit

import (
	"encoding/json"
	"testing"
	"time"
)

// seal builds a valid chain of n events exactly as the live Append path does, so
// any post-hoc mutation of a stored row is a faithful "tamperer edits the DB"
// scenario. Distinct from chain_test.buildChain (different helper, no collision).
func seal(tenant string, n int) []Event {
	events := make([]Event, 0, n)
	prev := ""
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 1; i <= n; i++ {
		e := Event{
			TenantID: tenant,
			Seq:      int64(i),
			Ts:       base.Add(time.Duration(i) * time.Minute),
			Actor:    "api-key:k" + intToStr(i),
			Action:   "key.issue",
			Target:   "resource/" + intToStr(i),
			Payload:  json.RawMessage(`{"i":` + intToStr(i) + `}`),
			PrevHash: prev,
		}
		e.Hash = ComputeHash(e)
		events = append(events, e)
		prev = e.Hash
	}
	return events
}

func intToStr(i int) string {
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var buf [20]byte
	pos := len(buf)
	for i > 0 {
		pos--
		buf[pos] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		pos--
		buf[pos] = '-'
	}
	return string(buf[pos:])
}

// TestVerifyChain_TamperEveryHashedFieldAtEveryLink is the load-bearing matrix:
// for each hashed field, mutate it at link i (leaving the stored hash stale, as a
// DB-row editor would) and assert the chain breaks at exactly seq=i with
// reason=hash_mismatch. A vacuous verifier that always returns intact fails this.
func TestVerifyChain_TamperEveryHashedFieldAtEveryLink(t *testing.T) {
	const n = 6
	mutators := []struct {
		name  string
		apply func(e *Event)
	}{
		{"actor", func(e *Event) { e.Actor = "api-key:attacker" }},
		{"action", func(e *Event) { e.Action = "key.revoke" }},
		{"target", func(e *Event) { e.Target = "other/resource" }},
		{"payload", func(e *Event) { e.Payload = json.RawMessage(`{"i":99999}`) }},
		{"tenant_id", func(e *Event) { e.TenantID = "tnt-EVIL" }},
		{"ts", func(e *Event) { e.Ts = e.Ts.Add(time.Second) }},
	}
	for _, m := range mutators {
		for link := 1; link <= n; link++ {
			t.Run(m.name+"_at_seq"+intToStr(link), func(t *testing.T) {
				events := seal("tnt-A", n)
				m.apply(&events[link-1]) // leave Hash stale
				res := VerifyChain("tnt-A", events)
				if res.Intact {
					t.Fatalf("tamper %s at seq=%d must break the chain", m.name, link)
				}
				if res.BrokenSeq != int64(link) {
					t.Fatalf("tamper %s: broke at seq=%d, want %d (reason=%s)", m.name, res.BrokenSeq, link, res.Reason)
				}
				if res.Reason != "hash_mismatch" {
					t.Fatalf("tamper %s at seq=%d: reason=%s, want hash_mismatch", m.name, link, res.Reason)
				}
			})
		}
	}
}

// TestVerifyChain_SeqTampering covers seq holes, reorders, duplicates, and a
// wrong genesis seq — all must surface as seq_gap at the first offending link.
func TestVerifyChain_SeqTampering(t *testing.T) {
	t.Run("delete_middle_row", func(t *testing.T) {
		events := seal("t", 5)
		spliced := append(append([]Event{}, events[:2]...), events[3:]...) // drop seq 3
		res := VerifyChain("t", spliced)
		if res.Intact || res.Reason != "seq_gap" {
			t.Fatalf("deleted row must be seq_gap, got %+v", res)
		}
		if res.BrokenSeq != 4 {
			t.Fatalf("deleted seq=3 surfaces at the row now mis-seated (seq=4), got broken_seq=%d", res.BrokenSeq)
		}
	})
	t.Run("genesis_seq_not_one", func(t *testing.T) {
		events := seal("t", 3)
		events[0].Seq = 2 // genesis must be 1
		res := VerifyChain("t", events)
		if res.Intact || res.Reason != "seq_gap" || res.BrokenSeq != 2 {
			t.Fatalf("wrong genesis seq must break at the first link as seq_gap, got %+v", res)
		}
	})
	t.Run("reorder_swaps_seq", func(t *testing.T) {
		events := seal("t", 4)
		events[1], events[2] = events[2], events[1] // now seqs go 1,3,2,4
		res := VerifyChain("t", events)
		if res.Intact || res.Reason != "seq_gap" {
			t.Fatalf("reordered rows must break as seq_gap, got %+v", res)
		}
	})
	t.Run("duplicate_seq", func(t *testing.T) {
		events := seal("t", 3)
		events[2].Seq = 2 // 1,2,2
		res := VerifyChain("t", events)
		if res.Intact || res.Reason != "seq_gap" {
			t.Fatalf("duplicate seq must break as seq_gap, got %+v", res)
		}
	})
}

// TestVerifyChain_PrevHashSplicing covers prev_hash tampering: splicing a link to
// a foreign hash, zeroing genesis-prev on a non-genesis row, and a non-empty
// genesis prev_hash. All surface as prev_hash_mismatch at the first bad link.
func TestVerifyChain_PrevHashSplicing(t *testing.T) {
	t.Run("splice_middle", func(t *testing.T) {
		events := seal("t", 5)
		events[2].PrevHash = "deadbeefdeadbeef"
		res := VerifyChain("t", events)
		if res.Intact || res.Reason != "prev_hash_mismatch" || res.BrokenSeq != 3 {
			t.Fatalf("spliced prev_hash must break at seq=3, got %+v", res)
		}
	})
	t.Run("nonempty_genesis_prev", func(t *testing.T) {
		events := seal("t", 3)
		events[0].PrevHash = "not-empty"
		// recompute genesis hash so the prev check (which runs before the hash
		// recompute) is the one that fires, not hash_mismatch.
		events[0].Hash = recompute(events[0])
		res := VerifyChain("t", events)
		if res.Intact || res.Reason != "prev_hash_mismatch" || res.BrokenSeq != 1 {
			t.Fatalf("non-empty genesis prev_hash must break at seq=1 prev_hash_mismatch, got %+v", res)
		}
	})
	t.Run("prev_points_at_wrong_earlier_link", func(t *testing.T) {
		events := seal("t", 5)
		events[3].PrevHash = events[0].Hash // should be events[2].Hash
		res := VerifyChain("t", events)
		if res.Intact || res.Reason != "prev_hash_mismatch" || res.BrokenSeq != 4 {
			t.Fatalf("prev pointing at the wrong earlier link must break at seq=4, got %+v", res)
		}
	})
}

// TestVerifyChain_FirstBreakWins proves only the FIRST break is reported even
// when multiple links are tampered (the forensic contract: earliest divergence).
func TestVerifyChain_FirstBreakWins(t *testing.T) {
	events := seal("t", 6)
	events[4].Actor = "late-tamper"                 // seq 5
	events[1].Payload = json.RawMessage(`{"i":-1}`) // seq 2 (earlier)
	res := VerifyChain("t", events)
	if res.Intact || res.BrokenSeq != 2 {
		t.Fatalf("first (earliest) break must win; want seq=2, got %+v", res)
	}
}

// TestComputeHash_PrevHashBinds proves prev_hash is part of the digest — the same
// event fields under a different prev_hash hash differently (so you cannot move a
// sealed link to a new position without changing its hash).
func TestComputeHash_PrevHashBinds(t *testing.T) {
	ts := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	h1 := ComputeHash(Event{PrevHash: "aaaa", TenantID: "t", Seq: 2, Ts: ts, Actor: "a", Action: "act", Target: "tgt", Payload: []byte(`{}`)})
	h2 := ComputeHash(Event{PrevHash: "bbbb", TenantID: "t", Seq: 2, Ts: ts, Actor: "a", Action: "act", Target: "tgt", Payload: []byte(`{}`)})
	if h1 == h2 {
		t.Fatal("prev_hash must bind into the digest")
	}
}

// TestComputeHash_FieldInjectionMatrix extends the injective-encoding guarantee:
// shifting characters across ANY adjacent semantic field boundary must change the
// hash (no actor/action/target/tenant confusion collisions).
func TestComputeHash_FieldInjectionMatrix(t *testing.T) {
	ts := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	type fields struct{ tenant, actor, action, target string }
	pairs := []struct {
		name string
		a, b fields
	}{
		{"actor_action_shift", fields{"t", "ab", "c", "x"}, fields{"t", "a", "bc", "x"}},
		{"action_target_shift", fields{"t", "a", "bc", "d"}, fields{"t", "a", "b", "cd"}},
		{"tenant_actor_shift", fields{"ab", "c", "x", "y"}, fields{"a", "bc", "x", "y"}},
		{"empty_vs_filled", fields{"t", "", "ab", "x"}, fields{"t", "a", "b", "x"}},
	}
	for _, p := range pairs {
		t.Run(p.name, func(t *testing.T) {
			h1 := ComputeHash(Event{TenantID: p.a.tenant, Seq: 1, Ts: ts, Actor: p.a.actor, Action: p.a.action, Target: p.a.target, Payload: []byte(`{}`)})
			h2 := ComputeHash(Event{TenantID: p.b.tenant, Seq: 1, Ts: ts, Actor: p.b.actor, Action: p.b.action, Target: p.b.target, Payload: []byte(`{}`)})
			if h1 == h2 {
				t.Fatalf("field-boundary shift %s produced a hash collision", p.name)
			}
		})
	}
}

// TestComputeHash_PayloadCanonicalization proves semantically-equal payloads
// (key order, nested key order, whitespace) hash identically, while any value
// change diverges — so re-serialization never false-positives but tampering does.
func TestComputeHash_PayloadCanonicalization(t *testing.T) {
	ts := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	h := func(p string) string {
		return ComputeHash(Event{TenantID: "t", Seq: 1, Ts: ts, Actor: "a", Action: "act", Target: "tgt", Payload: []byte(p)})
	}
	equal := [][2]string{
		{`{"x":1,"y":2}`, `{"y":2,"x":1}`},
		{`{"a":{"p":1,"q":2}}`, `{"a":{"q":2,"p":1}}`},
		{`{"x":1, "y":2}`, `{"x":1,"y":2}`}, // insignificant whitespace
		{``, `{}`},                          // empty canonicalizes to {}
		{`garbage-not-json`, `{}`},          // invalid canonicalizes to {} (no panic)
	}
	for i, pair := range equal {
		t.Run("equal_"+intToStr(i), func(t *testing.T) {
			if h(pair[0]) != h(pair[1]) {
				t.Fatalf("payloads %q and %q must hash identically", pair[0], pair[1])
			}
		})
	}
	diff := [][2]string{
		{`{"x":1}`, `{"x":2}`},
		{`{"x":1}`, `{"y":1}`},
		{`{"a":[1,2,3]}`, `{"a":[1,3,2]}`}, // array order IS significant
		{`{}`, `{"x":1}`},
	}
	for i, pair := range diff {
		t.Run("diff_"+intToStr(i), func(t *testing.T) {
			if h(pair[0]) == h(pair[1]) {
				t.Fatalf("payloads %q and %q must hash differently", pair[0], pair[1])
			}
		})
	}
}
