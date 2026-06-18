package newslettersvc

// newslettersvcErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type newslettersvcErr string

func (e newslettersvcErr) Error() string { return string(e) }
