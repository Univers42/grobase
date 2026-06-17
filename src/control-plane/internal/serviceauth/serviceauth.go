package serviceauth

import (
	"bytes"
	"crypto/subtle"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// VerifyServiceRequest authenticates an internal service-to-service request.
// static mode (default): constant-time X-Service-Token compare — exactly the
// pre-existing behavior. hmac mode: requires a valid X-Service-Auth signature
// within ±SERVICE_AUTH_SKEW_SECS (default 120). Reads and RESTORES r.Body so
// handlers can still decode it.
//
// During a rotation window (INTERNAL_SERVICE_TOKEN_PREV non-empty) the request
// is accepted if it verifies under EITHER the current token OR the previous one,
// so a peer that has not yet rotated — or an in-flight token minted before the
// flip — is not rejected mid-rotation. With PREV empty the second arm is never
// taken and the path is byte-identical to single-key behavior.
func VerifyServiceRequest(r *http.Request, expected string) bool {
	if expected == "" {
		return false
	}
	prev := prevServiceToken()
	if !ServiceAuthHMAC() {
		return verifyStaticToken(r, expected, prev)
	}
	return verifyHMAC(r, expected, prev)
}

// verifyStaticToken evaluates BOTH arms unconditionally (no `||` short-circuit)
// so the timing of a verify does not leak which key matched. SecureCompare is
// constant-time per-arm; an empty prev returns false.
func verifyStaticToken(r *http.Request, expected, prev string) bool {
	got := r.Header.Get("X-Service-Token")
	curOK := SecureCompare(got, expected)
	prevOK := prev != "" && SecureCompare(got, prev)
	return curOK || prevOK
}

// verifyHMAC validates a v1 X-Service-Auth signature against the current and
// (during rotation) previous token, within the configured clock skew.
func verifyHMAC(r *http.Request, expected, prev string) bool {
	hdr := r.Header.Get("X-Service-Auth")
	parts := strings.Split(hdr, ".")
	if len(parts) != 3 || parts[0] != "v1" {
		return false
	}
	ts, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return false
	}
	now := time.Now().Unix()
	if skew := serviceAuthSkew(); ts < now-skew || ts > now+skew {
		return false
	}
	body := readAndRestoreBody(r)
	msg := SignedRequest{Method: r.Method, Path: r.URL.Path, Body: body, TS: ts}
	want := ComputeServiceSignature(expected, msg)
	curOK := subtle.ConstantTimeCompare([]byte(hdr), []byte(want)) == 1
	prevOK := false
	if prev != "" {
		wantPrev := ComputeServiceSignature(prev, msg)
		prevOK = subtle.ConstantTimeCompare([]byte(hdr), []byte(wantPrev)) == 1
	}
	return curOK || prevOK
}

// serviceAuthSkew is the accepted clock skew in seconds (SERVICE_AUTH_SKEW_SECS,
// default 120). A non-positive or unparseable value keeps the default.
func serviceAuthSkew() int64 {
	skew := int64(120)
	if v := os.Getenv("SERVICE_AUTH_SKEW_SECS"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			skew = n
		}
	}
	return skew
}

// readAndRestoreBody reads the request body fully and restores it so downstream
// handlers can still decode it. Returns nil for a bodyless request.
func readAndRestoreBody(r *http.Request) []byte {
	if r.Body == nil {
		return nil
	}
	body, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()
	r.Body = io.NopCloser(bytes.NewReader(body))
	return body
}
