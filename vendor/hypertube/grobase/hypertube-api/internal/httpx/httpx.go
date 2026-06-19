// Package httpx carries the HTTP plumbing every handler shares: JSON encoding and
// RFC-7807 problem+json error bodies that never leak internals (no SQL/DSN/stack).
package httpx

import (
	"encoding/json"
	"net/http"
)

// WriteJSON encodes v as a JSON body with the given status and content type.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError emits an RFC-7807 problem+json body. title is a safe, caller-facing
// summary; internal detail (SQL, DSNs, stack traces) is never placed here.
func WriteError(w http.ResponseWriter, status int, title string) {
	w.Header().Set("Content-Type", "application/problem+json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(problem{Type: "about:blank", Title: title, Status: status})
}

// problem is the RFC-7807 error shape returned by WriteError.
type problem struct {
	Type   string `json:"type"`
	Title  string `json:"title"`
	Status int    `json:"status"`
}
