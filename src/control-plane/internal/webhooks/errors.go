package webhooks

// webhooksErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type webhooksErr string

func (e webhooksErr) Error() string { return string(e) }
