/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   httpauth_test.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:24 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:25 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package httpx

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func req(headers map[string]string) *http.Request {
	r, _ := http.NewRequest(http.MethodGet, "/", nil)
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	return r
}

func TestAPIKeyFromRequest(t *testing.T) {
	cases := []struct {
		name    string
		headers map[string]string
		want    string
	}{
		{"x-api-key wins", map[string]string{"X-API-Key": "mbk_abc", "Authorization": "Bearer mbk_zzz"}, "mbk_abc"},
		{"x-api-key trimmed", map[string]string{"X-API-Key": "  mbk_abc  "}, "mbk_abc"},
		{"bearer mbk", map[string]string{"Authorization": "Bearer mbk_xyz"}, "mbk_xyz"},
		{"bearer lowercase scheme", map[string]string{"Authorization": "bearer mbk_xyz"}, "mbk_xyz"},
		{"bearer mixed case scheme", map[string]string{"Authorization": "BeArEr mbk_xyz"}, "mbk_xyz"},
		{"bearer non-mbk ignored (jwt)", map[string]string{"Authorization": "Bearer eyJhbGci"}, ""},
		{"no headers", map[string]string{}, ""},
		{"empty x-api-key falls through", map[string]string{"X-API-Key": "   "}, ""},
		{"basic scheme ignored", map[string]string{"Authorization": "Basic mbk_abc"}, ""},
		{"bare token no scheme", map[string]string{"Authorization": "mbk_abc"}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := APIKeyFromRequest(req(c.headers)); got != c.want {
				t.Fatalf("APIKeyFromRequest = %q, want %q", got, c.want)
			}
		})
	}
}

// FuzzAPIKeyFromRequest asserts the parser never panics and never returns a key
// with surrounding whitespace or a non-mbk_ bearer value — for any input.
func FuzzAPIKeyFromRequest(f *testing.F) {
	f.Add("mbk_abc", "Bearer mbk_xyz")
	f.Add("", "bearer mbk_")
	f.Add("  ", "Basic x")
	f.Add("\x00", "Bearer \tmbk_\n")
	f.Fuzz(func(t *testing.T, xApiKey, authorization string) {
		r := req(map[string]string{"X-API-Key": xApiKey, "Authorization": authorization})
		got := APIKeyFromRequest(r)
		if got == "" {
			return
		}
		if got != strings.TrimSpace(got) {
			t.Fatalf("returned key has surrounding whitespace: %q", got)
		}
		// A returned key came either from X-API-Key (trimmed) or an mbk_ bearer.
		if strings.TrimSpace(xApiKey) == "" && !strings.HasPrefix(got, "mbk_") {
			t.Fatalf("bearer-sourced key not mbk_-prefixed: %q", got)
		}
	})
}

func TestRequireTenant(t *testing.T) {
	cases := []struct {
		name    string
		headers map[string]string
		want    string
		ok      bool
	}{
		{"tenant-id wins", map[string]string{"X-Baas-Tenant-Id": "t1", "X-User-Id": "u9"}, "t1", true},
		{"baas-user-id second", map[string]string{"X-Baas-User-Id": "u2", "X-Tenant-Id": "t9"}, "u2", true},
		{"tenant-id third", map[string]string{"X-Tenant-Id": "t3"}, "t3", true},
		{"user-id last", map[string]string{"X-User-Id": "u4"}, "u4", true},
		{"none -> 401", map[string]string{}, "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			got, ok := RequireTenant(rec, req(c.headers))
			if got != c.want || ok != c.ok {
				t.Fatalf("RequireTenant = (%q,%v), want (%q,%v)", got, ok, c.want, c.ok)
			}
			if !ok && rec.Code != http.StatusUnauthorized {
				t.Fatalf("miss must write 401, got %d", rec.Code)
			}
		})
	}
}

func TestCutBearer(t *testing.T) {
	cases := []struct {
		in  string
		tok string
		ok  bool
	}{
		{"Bearer x", "x", true},
		{"bearer  y ", "y", true},
		{"BEARER z", "z", true},
		{"Basic x", "", false},
		{"", "", false},
		{"Bearer", "", false},
	}
	for _, c := range cases {
		tok, ok := cutBearer(c.in)
		if tok != c.tok || ok != c.ok {
			t.Fatalf("cutBearer(%q) = (%q,%v), want (%q,%v)", c.in, tok, ok, c.tok, c.ok)
		}
	}
}
