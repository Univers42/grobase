package ipguard

// ipguardErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type ipguardErr string

func (e ipguardErr) Error() string { return string(e) }
