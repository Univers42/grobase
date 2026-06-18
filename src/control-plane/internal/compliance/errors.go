package compliance

// complianceErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type complianceErr string

func (e complianceErr) Error() string { return string(e) }
