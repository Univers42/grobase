package audit

// auditErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type auditErr string

func (e auditErr) Error() string { return string(e) }
