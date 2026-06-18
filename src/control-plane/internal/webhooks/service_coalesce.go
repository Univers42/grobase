package webhooks

import "encoding/json"

func coalesceMap(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

func coalesceStrSlice(s []string, fallback string) []string {
	if len(s) == 0 {
		return []string{fallback}
	}
	return s
}

func nullableHeaders(m map[string]string) any {
	if m == nil {
		return nil
	}
	b, _ := json.Marshal(m)
	return string(b)
}
