package audit

import "encoding/json"

// canonicalJSON re-serializes a JSON value with object keys sorted recursively,
// so two semantically equal payloads hash to the same bytes regardless of key
// order or insignificant whitespace. Invalid/empty JSON canonicalizes to "{}"
// (the table default) so a NULL/garbage payload never panics the chain.
func canonicalJSON(raw []byte) []byte {
	if len(raw) == 0 {
		return []byte("{}")
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return []byte("{}")
	}
	// json.Marshal sorts map[string]any keys, and our decoded objects are
	// map[string]any, so a re-marshal yields a key-sorted canonical form.
	out, err := json.Marshal(sortValue(v))
	if err != nil {
		return []byte("{}")
	}
	return out
}

// sortValue walks a decoded JSON value. json.Marshal already emits map keys in
// sorted order, so the walk just needs to recurse to normalize nested objects
// inside arrays (Marshal handles maps directly, but we recurse to be explicit
// and to keep the canonical form stable even if the encoder changes).
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
