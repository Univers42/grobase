package packages

import "sort"

// sortedStrings returns a sorted copy so ValidateWithin reports a DETERMINISTIC
// first-offending axis (map/slice iteration order would make the error message
// flaky across runs and across the two enforcement points).
func sortedStrings(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// sortedCapKeys returns the capability keys sorted, for the same determinism.
func sortedCapKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
