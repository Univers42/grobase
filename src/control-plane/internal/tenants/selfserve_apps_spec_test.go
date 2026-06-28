/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   selfserve_apps_spec_test.go                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// TestAppIdentity proves slug/db derivation: a valid canonical slug, an injection-safe db name,
// determinism per (user,name), no cross-account collision, and rejection of an alnum-less name.
func TestAppIdentity(t *testing.T) {
	slug, db, err := appIdentity("user-123", "My Cool App!")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasPrefix(slug, "app-my-cool-app-") {
		t.Fatalf("slug = %q, want app-my-cool-app-<hash>", slug)
	}
	if !provision.D().SlugPattern.MatchString(slug) {
		t.Fatalf("slug %q does not match the canonical slug pattern", slug)
	}
	if strings.Contains(db, "-") {
		t.Fatalf("db name %q must use underscores, not hyphens", db)
	}
	again, _, _ := appIdentity("user-123", "My Cool App!")
	if again != slug {
		t.Fatalf("not deterministic: %q vs %q", slug, again)
	}
	if other, _, _ := appIdentity("user-999", "My Cool App!"); other == slug {
		t.Fatal("distinct accounts must not collide on the same app name")
	}
	if _, _, err := appIdentity("u", "!!!"); err == nil {
		t.Fatal("expected an error for a name with no letter or digit")
	}
}

// TestAppDSN proves the control-plane DSN is rewritten to point at the app's fresh database.
func TestAppDSN(t *testing.T) {
	dsn, err := appDSN("postgres://u:p@db:5432/control", "app_foo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if dsn != "postgres://u:p@db:5432/app_foo" {
		t.Fatalf("appDSN = %q", dsn)
	}
}
