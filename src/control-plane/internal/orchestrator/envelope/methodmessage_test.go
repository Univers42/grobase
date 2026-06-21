/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   methodmessage_test.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:23 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:24 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package envelope

import (
	"net/http"
	"testing"
)

// TestMethodMessage_ParityTable pins the EXACT (message, ok) the former
// METHOD_MESSAGES map returned, now produced by a nested switch. The comma-ok
// flag must be true ONLY for a known (method,status) pair and false for an
// unknown method OR an unknown status of a known method — the same semantics a
// map lookup had. A drift here is the precise bug the map→switch conversion
// could introduce.
func TestMethodMessage_ParityTable(t *testing.T) {
	cases := []struct {
		method string
		status int
		want   string
		ok     bool
	}{
		// Known pairs (ok == true).
		{http.MethodGet, 200, "Data retrieved successfully", true},
		{http.MethodPost, 201, "Resource created successfully", true},
		{http.MethodPost, 200, "Operation successful", true},
		{http.MethodPut, 200, "Resource updated successfully", true},
		{http.MethodPatch, 200, "Resource updated successfully", true},
		{http.MethodDelete, 200, "Resource deleted successfully", true},
		// Known method, unknown status (ok == false, empty message).
		{http.MethodGet, 201, "", false},
		{http.MethodGet, 204, "", false},
		{http.MethodGet, 404, "", false},
		{http.MethodPost, 204, "", false},
		{http.MethodPost, 500, "", false},
		{http.MethodPut, 201, "", false},
		{http.MethodPatch, 204, "", false},
		{http.MethodDelete, 204, "", false},
		// Unknown methods (ok == false).
		{http.MethodHead, 200, "", false},
		{http.MethodOptions, 200, "", false},
		{"BREW", 200, "", false},
		{"", 200, "", false},
	}
	for _, c := range cases {
		got, ok := methodMessage(c.method, c.status)
		if got != c.want || ok != c.ok {
			t.Errorf("methodMessage(%q, %d) = (%q, %v), want (%q, %v)",
				c.method, c.status, got, ok, c.want, c.ok)
		}
	}
}

// TestMessage_FallbackForUnknown pins the message() fallback: any pair where
// methodMessage returns ok==false falls back to the literal "Operation
// successful" (the Node interceptor default), while known pairs pass through.
func TestMessage_FallbackForUnknown(t *testing.T) {
	cases := []struct {
		method string
		status int
		want   string
	}{
		{http.MethodGet, 200, "Data retrieved successfully"}, // known
		{http.MethodPost, 200, "Operation successful"},       // known (explicit literal)
		{http.MethodGet, 204, "Operation successful"},        // unknown status → fallback
		{http.MethodHead, 200, "Operation successful"},       // unknown method → fallback
		{"", 0, "Operation successful"},                      // wholly unknown → fallback
	}
	for _, c := range cases {
		if got := message(c.method, c.status); got != c.want {
			t.Errorf("message(%q, %d) = %q, want %q", c.method, c.status, got, c.want)
		}
	}
}

// FuzzMethodMessage asserts the parsing path never panics for any method/status
// and always preserves the comma-ok invariant: ok==true implies a non-empty
// message, ok==false implies the empty message.
func FuzzMethodMessage(f *testing.F) {
	f.Add(http.MethodGet, 200)
	f.Add(http.MethodPost, 201)
	f.Add("BREW", 418)
	f.Add("", 0)
	f.Add(http.MethodDelete, -1)
	f.Fuzz(func(t *testing.T, method string, status int) {
		msg, ok := methodMessage(method, status)
		if ok && msg == "" {
			t.Errorf("methodMessage(%q, %d): ok=true but empty message", method, status)
		}
		if !ok && msg != "" {
			t.Errorf("methodMessage(%q, %d): ok=false but non-empty message %q", method, status, msg)
		}
		// message() must never return empty (it falls back).
		if message(method, status) == "" {
			t.Errorf("message(%q, %d) returned empty string", method, status)
		}
	})
}
