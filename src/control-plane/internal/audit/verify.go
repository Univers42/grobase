package audit

// VerifyResult is the outcome of a chain verification for one tenant.
type VerifyResult struct {
	TenantID string `json:"tenant_id"`
	Count    int    `json:"count"`  // events examined
	Intact   bool   `json:"intact"` // true iff every link recomputes + links correctly
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
		if bad := verifyLink(res, e, i, prev, prevSeq); bad != nil {
			return *bad
		}
		prev = e.Hash
		prevSeq = e.Seq
	}
	return res
}

// verifyLink checks one link's seq contiguity, prev_hash linkage, and hash
// integrity in that order. It returns a *VerifyResult on the FIRST failing
// check (the first break wins) or nil when the link is intact.
func verifyLink(res VerifyResult, e Event, i int, prev string, prevSeq int64) *VerifyResult {
	// seq contiguity: first must be 1, each subsequent +1.
	wantSeq := prevSeq + 1
	if i == 0 {
		wantSeq = 1
	}
	if e.Seq != wantSeq {
		r := broken(res, e.Seq, "seq_gap", "", "")
		return &r
	}
	// prev_hash linkage to the previous stored hash.
	if e.PrevHash != prev {
		r := broken(res, e.Seq, "prev_hash_mismatch", prev, e.PrevHash)
		return &r
	}
	// hash integrity: recompute from THIS row's fields + its claimed prev.
	if want := recompute(e); want != e.Hash {
		r := broken(res, e.Seq, "hash_mismatch", want, e.Hash)
		return &r
	}
	return nil
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
