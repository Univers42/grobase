package shared

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
)

// SecureCompare reports whether the presented token equals the expected token,
// in constant time (Phase B / fix: the previous `==`/`!=` checks on the
// internal service token leaked length + prefix via timing). An empty `want`
// always returns false — an unset service token must never authorize a caller.
func SecureCompare(got, want string) bool {
	if want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// ServiceAuthHMAC reports whether SERVICE_TOKEN_MODE=hmac is active (audit O1).
// In hmac mode the shared token never transits the wire: callers send a
// per-request signature instead, and plain X-Service-Token is REJECTED.
func ServiceAuthHMAC() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("SERVICE_TOKEN_MODE")), "hmac")
}

// ComputeServiceSignature returns the v1 X-Service-Auth header value:
//
//	v1.<unix-ts>.<hex hmac-sha256(token, "<ts>\n<METHOD>\n<PATH>\n<sha256hex(body)>")>
//
// The signature binds time, method, path, and body, so an intercepted header
// cannot be replayed against another endpoint or with another payload. PATH is
// the URL path only — internal base URLs are origin-only and these routes take
// no query strings.
func ComputeServiceSignature(token, method, path string, body []byte, ts int64) string {
	bodySum := sha256.Sum256(body)
	msg := fmt.Sprintf("%d\n%s\n%s\n%s", ts, strings.ToUpper(method), path, hex.EncodeToString(bodySum[:]))
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte(msg))
	return fmt.Sprintf("v1.%d.%s", ts, hex.EncodeToString(mac.Sum(nil)))
}

// prevServiceToken returns the optional rotation-window previous token
// (INTERNAL_SERVICE_TOKEN_PREV). Empty (the default) means single-key behavior:
// only `expected` is accepted, byte-identical to before this hook existed.
//
// Rotation discipline (G-Rotate, in-repo half): set PREV = the current token,
// set the primary = the new token, roll the peers one at a time (each peer now
// ACCEPTS both, so an in-flight request signed under either is honored), then
// clear PREV after the grace window — after which the old token is REJECTED.
func prevServiceToken() string {
	return os.Getenv("INTERNAL_SERVICE_TOKEN_PREV")
}
