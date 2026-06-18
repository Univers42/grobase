package pg

// DerefStr returns the pointed-to string, or "" when the pointer is nil — the
// safe read of a nullable text column scanned into a *string.
func DerefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
