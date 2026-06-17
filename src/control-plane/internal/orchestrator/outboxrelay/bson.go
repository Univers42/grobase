package outboxrelay

// asObject returns v as a map only when it is a JSON object (not an array /
// scalar / nil) — the Go mirror of objectPayload applied to an already-decoded
// value.
func asObject(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return nil
}

// nullableValue maps "" → nil so an absent request_id is written as BSON null
// (parity with the Node `request_id: event.request_id` when null), consistent
// with realtimeBody and saga.go's nullable().
func nullableValue(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// bsonValue passes JSON-decoded values through. json.Unmarshal already yields
// driver-friendly Go types (map[string]any, []any, float64, string, bool, nil),
// so no conversion is needed; the indirection is a single seam for any future
// type coercion and keeps the builders readable.
func bsonValue(v any) any { return v }
