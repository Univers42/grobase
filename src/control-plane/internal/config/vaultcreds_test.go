/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   vaultcreds_test.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:33 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package config

import "testing"

// TestIsPlaceholderEncKey_Membership pins the EXACT set the former placeholder
// map (now a switch) refuses: the empty string (unset → no credential) plus the
// four publicly-known dev defaults baked into docker-compose.yml. A real-looking
// per-deployment secret must NOT be a placeholder. A case dropped or mistyped in
// the map→switch conversion is exactly what this guards.
func TestIsPlaceholderEncKey_Membership(t *testing.T) {
	placeholders := []string{
		"",                                 // unset → no credential at all
		"0123456789abcdef0123456789abcdef", // compose default-of-last-resort
		"changeme",
		"change-me",
		"dev-vault-enc-key",
	}
	for _, p := range placeholders {
		if !isPlaceholderEncKey(p) {
			t.Errorf("isPlaceholderEncKey(%q) = false, want true (placeholder dropped from set)", p)
		}
	}
	real := []string{
		"a-real-32-byte-vault-sourced-key!",
		"0123456789abcdef0123456789abcde", // 31 chars — one short of the compose default, NOT it
		"0123456789abcdef0123456789abcdefX",
		"CHANGEME",  // case-sensitive: not the lowercase placeholder
		"change_me", // underscore variant, not the hyphen one
		"vault-enc-key",
		" ", // a single space is a (bad but) non-placeholder value
	}
	for _, r := range real {
		if isPlaceholderEncKey(r) {
			t.Errorf("isPlaceholderEncKey(%q) = true, want false (real key rejected as placeholder)", r)
		}
	}
}

// TestValidateEncKey_PlaceholderAndLength couples the placeholder check to the
// length floor: a placeholder (incl. empty) is rejected, a real key shorter than
// minVaultEncKeyChars is rejected, and a real key of sufficient length passes —
// the exact contract requireVaultBackedCredentials relies on at SECURITY_MODE=max.
func TestValidateEncKey_PlaceholderAndLength(t *testing.T) {
	cases := []struct {
		name    string
		key     string
		wantErr bool
	}{
		{"empty rejected", "", true},
		{"compose placeholder rejected", "0123456789abcdef0123456789abcdef", true}, // 32 chars, but it's a placeholder
		{"changeme rejected", "changeme", true},
		{"short real key rejected", "tooshort", true},            // 8 < 16
		{"15-char real key rejected", "fifteenchars123", true},   // 15 < 16
		{"16-char real key accepted", "sixteenchars1234", false}, // exactly 16
		{"long real key accepted", "a-real-32-byte-vault-sourced-key!", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := validateEncKey(c.key)
			if (err != nil) != c.wantErr {
				t.Fatalf("validateEncKey(%q) err=%v, wantErr=%v", c.key, err, c.wantErr)
			}
		})
	}
}
