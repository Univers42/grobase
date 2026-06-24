package sources

import "fmt"

// statusError is a non-200 upstream status, modelled as a const-friendly error
// type so no sentinel var is needed (see .claude/rules/no-globals.md).
type statusError int

// Error renders the upstream HTTP status code.
func (e statusError) Error() string { return fmt.Sprintf("source upstream status %d", int(e)) }
