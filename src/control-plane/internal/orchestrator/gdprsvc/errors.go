package gdprsvc

// gdprsvcErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type gdprsvcErr string

func (e gdprsvcErr) Error() string { return string(e) }
