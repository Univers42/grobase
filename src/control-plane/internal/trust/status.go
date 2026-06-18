package trust

// isAllowedStatus reports whether s is in the closed enum a control's status
// MUST be in. A control outside this set is a malformed manifest (LoadManifest
// rejects it), which keeps the trust page from advertising a garbage/blank
// posture.
func isAllowedStatus(s string) bool {
	switch s {
	case "implemented", "partial", "planned":
		return true
	}
	return false
}
