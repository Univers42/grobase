/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   serviceauth.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:51 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:55:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

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

// VerifyServiceRequest reports whether r authenticates as an internal
// service-to-service request under the current OR (during a rotation window,
// INTERNAL_SERVICE_TOKEN_PREV non-empty) the previous token. It is the bool
// view of Verify — use Verify / RotationNotice.Accept to learn WHICH matched.
// With PREV empty the second arm is never taken and the path is byte-identical
// to single-key behavior.
func VerifyServiceRequest(r *http.Request, expected string) bool {
	return Verify(r, expected) != NoMatch
}

// verifyStaticToken evaluates BOTH arms unconditionally (no `||` short-circuit)
// so the timing of a verify does not leak which key matched, then folds them
// with pickMatch. SecureCompare is constant-time per-arm; an empty prev is false.
func verifyStaticToken(r *http.Request, expected, prev string) Match {
	got := r.Header.Get("X-Service-Token")
	curOK := SecureCompare(got, expected)
	prevOK := prev != "" && SecureCompare(got, prev)
	return pickMatch(curOK, prevOK)
}

// verifyHMAC validates a v1 X-Service-Auth signature against the current and
// (during rotation) previous token, within the configured clock skew, and
// reports which one signed it (both signatures are always computed first).
func verifyHMAC(r *http.Request, expected, prev string) Match {
	hdr := r.Header.Get("X-Service-Auth")
	parts := strings.Split(hdr, ".")
	if len(parts) != 3 || parts[0] != "v1" {
		return NoMatch
	}
	ts, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return NoMatch
	}
	now := time.Now().Unix()
	if skew := serviceAuthSkew(); ts < now-skew || ts > now+skew {
		return NoMatch
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
	return pickMatch(curOK, prevOK)
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
