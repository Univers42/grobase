package shared

import (
	"encoding/json"
	"net/http"
	"regexp"
)

// dsnRe matches a connection-string-shaped substring (scheme://[creds@]host…),
// e.g. postgres://user:pass@db:5432/app or redis://:secret@cache:6379. Used to
// scrub DSNs that an upstream service may echo back inside an error body before
// the message is surfaced to a caller / log.
var dsnRe = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'\\]+`)

// RedactDSN replaces any DSN-shaped substring with a placeholder so credentials
// reflected in an upstream error body never leak into a ResourceResult.Error or
// a log line.
func RedactDSN(s string) string {
	return dsnRe.ReplaceAllString(s, "[redacted-dsn]")
}

// WriteJSON serializes v as a JSON response with the given status code.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError emits a structured JSON error.
func WriteError(w http.ResponseWriter, status int, code, message string) {
	WriteJSON(w, status, map[string]any{"error": code, "message": message, "statusCode": status})
}
