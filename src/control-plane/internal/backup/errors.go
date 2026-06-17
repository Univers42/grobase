package backup

// backupErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type backupErr string

func (e backupErr) Error() string { return string(e) }
