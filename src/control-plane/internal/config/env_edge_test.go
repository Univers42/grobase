/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   env_edge_test.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:19 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:20 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package config

import "testing"

// TestEnvBool_TruthyClosedSet pins the EXACT truthy set the former conversion
// preserved: ONLY "1"/"true"/"on" and their all-caps/title forms are truthy.
// Everything else — including near-misses like " 1 " (whitespace), "yes",
// "TrUe" (mixed case not in the case-list), and the numeral 2 — is false. This
// is the canonical flag-gate read; a loosened predicate would silently mount a
// cloud route that should be byte-parity-OFF.
func TestEnvBool_TruthyClosedSet(t *testing.T) {
	truthy := []string{"1", "true", "on", "TRUE", "True", "ON"}
	for _, v := range truthy {
		t.Setenv("CP_EDGE_BOOL", v)
		if !EnvBool("CP_EDGE_BOOL") {
			t.Errorf("EnvBool(%q) = false, want true", v)
		}
	}
	falsy := []string{
		" 1", "1 ", " true ", "yes", "y", "0", "false", "off", "no",
		"2", "-1", "TrUe", "On ", "enabled", "garbage", "\t1",
	}
	for _, v := range falsy {
		t.Setenv("CP_EDGE_BOOL", v)
		if EnvBool("CP_EDGE_BOOL") {
			t.Errorf("EnvBool(%q) = true, want false (truthy set must stay closed)", v)
		}
	}
}

// TestEnvBool_Unset confirms an unset var is false (the byte-parity default).
func TestEnvBool_Unset(t *testing.T) {
	// CP_EDGE_BOOL_UNSET is never set in this process.
	if EnvBool("CP_EDGE_BOOL_UNSET") {
		t.Error("EnvBool(unset) = true, want false")
	}
}

// TestEnvInt_Edges covers the parse edge cases: negative, zero, leading-plus,
// overflow-ish, and whitespace — falling back to def only when unparseable.
func TestEnvInt_Edges(t *testing.T) {
	cases := []struct {
		val  string
		def  int
		want int
	}{
		{"-5", 7, -5},
		{"0", 7, 0},
		{"+12", 7, 12},
		{"  9  ", 7, 7}, // strconv.Atoi rejects surrounding whitespace → def
		{"3.5", 7, 7},   // not an int → def
		{"1e3", 7, 7},   // not an int → def
		{"", 7, 7},      // empty → def
		{"notanumber", 7, 7},
	}
	for _, c := range cases {
		t.Setenv("CP_EDGE_INT", c.val)
		if got := EnvInt("CP_EDGE_INT", c.def); got != c.want {
			t.Errorf("EnvInt(%q, %d) = %d, want %d", c.val, c.def, got, c.want)
		}
	}
}

// TestEnvStr_EmptyIsDefault confirms an explicitly-empty var falls back to def
// (EnvStr treats "" the same as unset — the documented contract).
func TestEnvStr_EmptyIsDefault(t *testing.T) {
	t.Setenv("CP_EDGE_STR", "")
	if got := EnvStr("CP_EDGE_STR", "fallback"); got != "fallback" {
		t.Errorf("EnvStr(empty) = %q, want fallback", got)
	}
	t.Setenv("CP_EDGE_STR", " ") // a space is a real value, NOT empty
	if got := EnvStr("CP_EDGE_STR", "fallback"); got != " " {
		t.Errorf("EnvStr(space) = %q, want a single space", got)
	}
}
