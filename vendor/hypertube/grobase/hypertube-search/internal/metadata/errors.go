package metadata

import "fmt"

// statusError is a TMDb non-200 status, modelled as a const-friendly error type
// (no sentinel var — see .claude/rules/no-globals.md).
type statusError int

// Error renders the upstream TMDb status code.
func (e statusError) Error() string { return fmt.Sprintf("tmdb upstream status %d", int(e)) }
