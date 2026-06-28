/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mint_test.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package appchannels

import (
	"reflect"
	"testing"
)

// TestRealtimeNamespaces proves a token grants exactly one xapp:<id> per accepted channel and
// NOTHING else — no wildcard (so the `**`/`*` glob is denied), and an empty grant when there are
// no accepted channels (the token reaches no topic at all).
func TestRealtimeNamespaces(t *testing.T) {
	got := realtimeNamespaces([]string{"abc", "def"})
	want := []string{"xapp:abc", "xapp:def"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("realtimeNamespaces = %v, want %v", got, want)
	}
	for _, ns := range got {
		if ns == "*" {
			t.Fatal("a channel token must NOT carry the \"*\" wildcard")
		}
	}
	if g := realtimeNamespaces(nil); len(g) != 0 {
		t.Fatalf("no channels: got %v, want []", g)
	}
}

// TestHasScope proves the scope gate: an exact scope or an admin scope grants; nothing else does.
func TestHasScope(t *testing.T) {
	cases := []struct {
		scopes []string
		want   string
		ok     bool
	}{
		{[]string{"read", "write"}, "write", true},
		{[]string{"read"}, "write", false},
		{[]string{"admin"}, "write", true},
		{[]string{"apikey:admin"}, "read", true},
		{nil, "read", false},
	}
	for _, c := range cases {
		if got := hasScope(c.scopes, c.want); got != c.ok {
			t.Errorf("hasScope(%v, %q) = %v, want %v", c.scopes, c.want, got, c.ok)
		}
	}
}
