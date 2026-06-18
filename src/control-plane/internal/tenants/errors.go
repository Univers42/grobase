package tenants

// tenantsErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type tenantsErr string

func (e tenantsErr) Error() string { return string(e) }
