package users

import (
	"encoding/json"
	"net/http"

	"hypertube/api/internal/store"
)

// editableFields is the allowlist of profile keys a user may PATCH on themselves.
// Identity-bearing keys (id, owner_id, tenant_id) are deliberately excluded.
func editableFields(key string) bool {
	switch key {
	case "username", "first_name", "last_name", "avatar_url", "preferred_language":
		return true
	default:
		return false
	}
}

// decodePatch reads a JSON body and keeps only allowlisted, non-empty fields.
// It returns ok=false for a non-object body or a patch that touches no editable
// field (a 400 case — the contract rejects empty/invalid updates).
func decodePatch(r *http.Request) (store.Row, bool) {
	var raw map[string]any
	if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&raw); err != nil {
		return nil, false
	}
	patch := store.Row{}
	for k, v := range raw {
		if editableFields(k) {
			patch[k] = v
		}
	}
	if len(patch) == 0 {
		return nil, false
	}
	return patch, true
}
