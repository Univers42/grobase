package jsoncanon

import "encoding/json"

// CanonicalJSON re-serializes a JSON value with object keys sorted recursively,
// so two semantically equal payloads hash to the same bytes regardless of key
// order or insignificant whitespace. Invalid/empty JSON canonicalizes to "{}"
// so a NULL/garbage payload never panics a hash chain. This is the single source
// of truth for the audit chain (audit.chain) and the compliance seal — both hash
// over its output, so they MUST canonicalize identically. json.Marshal sorts
// map[string]any keys and our decoded objects are map[string]any, so the
// re-marshal yields a key-sorted canonical form.
func CanonicalJSON(raw []byte) []byte {
	if len(raw) == 0 {
		return []byte("{}")
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return []byte("{}")
	}
	out, err := json.Marshal(sortValue(v))
	if err != nil {
		return []byte("{}")
	}
	return out
}

// sortValue walks a decoded JSON value. json.Marshal already emits map keys in
// sorted order, so the walk just needs to recurse to normalize nested objects
// inside arrays (we recurse to be explicit and keep the form stable even if the
// encoder changes).
func sortValue(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, val := range t {
			out[k] = sortValue(val)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, val := range t {
			out[i] = sortValue(val)
		}
		return out
	default:
		return v
	}
}
