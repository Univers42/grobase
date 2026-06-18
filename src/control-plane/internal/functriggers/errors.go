package functriggers

// functriggersErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type functriggersErr string

func (e functriggersErr) Error() string { return string(e) }
