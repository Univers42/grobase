/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   match_test.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/25 10:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/25 10:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package serviceauth

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const (
	matchCur  = "match-current-token"
	matchPrev = "match-previous-token"
)

// matchCase is one Verify expectation: the token the caller presents, the PREV
// window value, and the Match the verifier must return.
type matchCase struct {
	name, presented, prev string
	want                  Match
}

// matchCases covers every arm of the current/previous decision, including the
// both-match case where current must win over previous.
func matchCases() []matchCase {
	return []matchCase{
		{"only-current", matchCur, matchPrev, MatchedCurrent},
		{"only-previous", matchPrev, matchPrev, MatchedPrevious},
		{"both-match-current-wins", matchCur, matchCur, MatchedCurrent},
		{"neither", "stranger-token", matchPrev, NoMatch},
		{"previous-after-window-closed", matchPrev, "", NoMatch},
	}
}

// TestVerifyStaticMatch proves static-mode Verify reports WHICH token matched,
// and that the bool wrapper agrees with it on every case.
func TestVerifyStaticMatch(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "")
	for _, c := range matchCases() {
		t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", c.prev)
		r := httptest.NewRequest(http.MethodPost, "/v1/keys/verify", bytes.NewReader([]byte(`{}`)))
		r.Header.Set("X-Service-Token", c.presented)
		if got := Verify(r, matchCur); got != c.want {
			t.Errorf("%s: Verify = %d, want %d", c.name, got, c.want)
		}
		if VerifyServiceRequest(r, matchCur) != (c.want != NoMatch) {
			t.Errorf("%s: VerifyServiceRequest disagrees with Verify", c.name)
		}
	}
}

// TestVerifyHMACMatch proves hmac-mode Verify reports WHICH token signed the
// request.
func TestVerifyHMACMatch(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "hmac")
	body := []byte(`{"key":"abc"}`)
	ts := time.Now().Unix()
	for _, c := range matchCases() {
		t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", c.prev)
		r := httptest.NewRequest(http.MethodPost, "/v1/keys/verify", bytes.NewReader(body))
		sig := ComputeServiceSignature(c.presented, SignedRequest{Method: http.MethodPost, Path: "/v1/keys/verify", Body: body, TS: ts})
		r.Header.Set("X-Service-Auth", sig)
		if got := Verify(r, matchCur); got != c.want {
			t.Errorf("%s: Verify = %d, want %d", c.name, got, c.want)
		}
	}
}

// TestVerifyEmptyExpectedIsNoMatch keeps the unset-token guard: an empty
// expected token never authorizes, even when PREV matches the header, and
// NoMatch is the zero value so an unset Match never reads as accepted.
func TestVerifyEmptyExpectedIsNoMatch(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "")
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", matchPrev)
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("X-Service-Token", matchPrev)
	if got := Verify(r, ""); got != NoMatch {
		t.Fatalf("empty expected: Verify = %d, want NoMatch", got)
	}
	var zero Match
	if zero != NoMatch {
		t.Fatal("NoMatch must be the zero value")
	}
}
