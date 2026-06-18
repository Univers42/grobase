package newslettersvc

import (
	"net/http"
	"strconv"
	"strings"
)

func validEmail(s string) bool {
	at := strings.IndexByte(s, '@')
	return at > 0 && at < len(s)-1 && len(s) <= 255 &&
		strings.IndexByte(s[at+1:], '.') >= 0 && !strings.ContainsAny(s, " \t")
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func firstOr(first string, fallback *string) string {
	if first != "" {
		return first
	}
	if fallback != nil {
		return *fallback
	}
	return ""
}

func queryInt(r *http.Request, key string, def int) int {
	if v := r.URL.Query().Get(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
