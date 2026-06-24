/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   respond_test.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package httpx

import "testing"

func TestRedactDSN(t *testing.T) {
	cases := map[string]bool{ // input -> should contain redaction marker
		"connect failed: postgres://user:secret@db:5432/app":      true,
		"redis://:topsecret@cache:6379 unreachable":               true,
		"adapter-registry 400: validation_error (no dsn here)":    false,
		"mongodb+srv://u:p@cluster0.mongodb.net/test auth failed": true,
	}
	for in, wantRedacted := range cases {
		out := RedactDSN(in)
		if wantRedacted {
			if out == in {
				t.Errorf("RedactDSN(%q) left a DSN unredacted: %q", in, out)
			}
			if !contains(out, "[redacted-dsn]") {
				t.Errorf("RedactDSN(%q) = %q, want redaction marker", in, out)
			}
			if contains(out, "secret") || contains(out, "topsecret") {
				t.Errorf("RedactDSN(%q) leaked a credential: %q", in, out)
			}
		} else if out != in {
			t.Errorf("RedactDSN(%q) changed a non-DSN message: %q", in, out)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
