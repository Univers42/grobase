/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rotation_test.go                                   :+:      :+:    :+:   */
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
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeSink records every counter increment the notice forwards.
type fakeSink struct{ names []string }

// IncCounter appends the counter name so the test can count increments.
func (f *fakeSink) IncCounter(name, _, _, _ string) { f.names = append(f.names, name) }

// TestRotationNoticeLogsOnce proves N previous-token acceptances emit exactly
// ONE warning, bump the counter N times, and never log either token.
func TestRotationNoticeLogsOnce(t *testing.T) {
	var buf bytes.Buffer
	sink := &fakeSink{}
	n := NewRotationNotice(slog.New(slog.NewTextHandler(&buf, nil)), sink)
	for range 7 {
		n.Observe(MatchedPrevious)
	}
	if got := strings.Count(buf.String(), "rotation window open"); got != 1 {
		t.Fatalf("warning logged %d times, want 1; log=%q", got, buf.String())
	}
	if len(sink.names) != 7 || sink.names[0] != "baas_service_token_previous_accepted_total" {
		t.Fatalf("counter increments = %v, want 7x baas_service_token_previous_accepted_total", sink.names)
	}
	for _, secret := range []string{matchCur, matchPrev} {
		if strings.Contains(buf.String(), secret) {
			t.Fatalf("log leaked a token: %q", buf.String())
		}
	}
}

// TestRotationNoticeIgnoresCurrentAndNoMatch proves only a previous-token
// acceptance is signalled, and a nil notice / nil sink is a safe no-op.
func TestRotationNoticeIgnoresCurrentAndNoMatch(t *testing.T) {
	var buf bytes.Buffer
	sink := &fakeSink{}
	n := NewRotationNotice(slog.New(slog.NewTextHandler(&buf, nil)), sink)
	n.Observe(MatchedCurrent)
	n.Observe(NoMatch)
	if buf.Len() != 0 || len(sink.names) != 0 {
		t.Fatalf("current/no-match must be silent; log=%q counter=%v", buf.String(), sink.names)
	}
	var nilNotice *RotationNotice
	nilNotice.Observe(MatchedPrevious)
	NewRotationNotice(slog.New(slog.NewTextHandler(&buf, nil)), nil).Observe(MatchedPrevious)
	if strings.Count(buf.String(), "rotation window open") != 1 {
		t.Fatalf("nil-sink notice must still log once; log=%q", buf.String())
	}
}

// TestRotationNoticeAccept proves Accept is Verify + Observe: a previous-token
// request is accepted AND signalled; a nil notice still authenticates.
func TestRotationNoticeAccept(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "")
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", matchPrev)
	sink := &fakeSink{}
	n := NewRotationNotice(slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)), sink)
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("X-Service-Token", matchPrev)
	var nilNotice *RotationNotice
	if !n.Accept(r, matchCur) || !nilNotice.Accept(r, matchCur) || len(sink.names) != 1 {
		t.Fatalf("previous token must be accepted and counted once; counter=%v", sink.names)
	}
	r.Header.Set("X-Service-Token", "stranger-token")
	if n.Accept(r, matchCur) {
		t.Fatal("a stranger token must be rejected")
	}
}

// TestRotationNoticeCurrentZeroAlloc pins the hot path: observing a current-
// token match allocates nothing.
func TestRotationNoticeCurrentZeroAlloc(t *testing.T) {
	n := NewRotationNotice(slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)), &fakeSink{})
	if a := testing.AllocsPerRun(1000, func() { n.Observe(MatchedCurrent) }); a != 0 {
		t.Fatalf("Observe(MatchedCurrent) allocs = %v, want 0", a)
	}
}
