package sessionsvc

// sessionsvcErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type sessionsvcErr string

func (e sessionsvcErr) Error() string { return string(e) }
