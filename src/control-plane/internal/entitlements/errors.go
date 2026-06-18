package entitlements

// entitlementsErr is the package's const-error type: a sentinel is a typed
// string constant, so errors.Is / %w wrapping still work (equal value+type ==
// equal error) with no package-level var.
type entitlementsErr string

func (e entitlementsErr) Error() string { return string(e) }

// ErrNotFound is returned by Load when no entitlement row exists for the slug.
const ErrNotFound entitlementsErr = "no entitlement for tenant"
