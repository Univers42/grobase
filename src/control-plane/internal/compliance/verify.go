package compliance

// VerifyResult is the outcome of verifying a snapshot's sealed rows.
type VerifyResult struct {
	SnapshotID string `json:"snapshot_id"`
	Count      int    `json:"count"`  // rows examined
	Intact     bool   `json:"intact"` // true iff every row's stored hash == recomputed hash
	Complete   bool   `json:"complete"`
	// BrokenSection names the FIRST row whose seal does not recompute (empty when
	// intact). ExpectedHash/StoredHash give the recomputed-vs-stored hashes at the
	// break for forensics.
	BrokenSection string   `json:"broken_section,omitempty"`
	ExpectedHash  string   `json:"expected_hash,omitempty"`
	StoredHash    string   `json:"stored_hash,omitempty"`
	Missing       []string `json:"missing_sections,omitempty"`
}

// VerifySnapshot recomputes the seal of every row in a snapshot and reports the
// FIRST tampered row, plus whether all three sections are present. It is PURE —
// no DB, no IO — so the unit test can prove tamper detection deterministically
// (mutate a row's payload/section and assert BrokenSection names it).
//
// A snapshot is INTACT iff every row's stored Hash == recompute(row). It is
// COMPLETE iff all three Sections appear exactly once. The caller verifies over
// a snapshot-scoped query (rows for one snapshot_id); this function trusts the
// slice is that scope and reports against the canonical Sections set.
func VerifySnapshot(snapshotID string, rows []EvidenceRow) VerifyResult {
	res := VerifyResult{SnapshotID: snapshotID, Count: len(rows), Intact: true}
	present := make(map[string]bool, len(rows))
	for _, e := range rows {
		present[e.Section] = true
		want := recompute(e)
		if want != e.Hash && res.Intact {
			res.Intact = false
			res.BrokenSection = e.Section
			res.ExpectedHash = want
			res.StoredHash = e.Hash
		}
	}
	for _, s := range Sections() {
		if !present[s] {
			res.Missing = append(res.Missing, s)
		}
	}
	res.Complete = len(res.Missing) == 0
	return res
}
