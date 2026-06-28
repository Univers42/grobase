/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   selfserve_apps_spec.go                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// appIdentity derives a stable, unique app-tenant slug and its database name from the account
// user id + the requested name. The slug is "app-<sanitized-name>-<8 hex of sha256(userID)>"
// (so the same name re-creates the same app idempotently, and two accounts never collide); the
// db name is that slug with '-'→'_'. Both fit the canonical slug pattern / Postgres identifier.
func appIdentity(userID, name string) (string, string, error) {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(name)) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case b.Len() > 0 && b.String()[b.Len()-1] != '-':
			b.WriteByte('-')
		}
	}
	clean := strings.Trim(b.String(), "-")
	if len(clean) > 40 {
		clean = strings.Trim(clean[:40], "-")
	}
	if clean == "" {
		return "", "", fmt.Errorf("name must contain at least one letter or digit")
	}
	sum := sha256.Sum256([]byte(userID))
	slug := "app-" + clean + "-" + hex.EncodeToString(sum[:])[:16]
	if !provision.D().SlugPattern.MatchString(slug) {
		return "", "", fmt.Errorf("could not derive a valid app slug from %q", name)
	}
	return slug, strings.ReplaceAll(slug, "-", "_"), nil
}

// appDSN is the control-plane DSN with its database path swapped to the app's fresh database.
func appDSN(base, dbName string) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	u.Path = "/" + dbName
	return u.String(), nil
}

// buildAppSpec is the provisioning spec for one app: a postgresql mount on the fresh DB (shared_rls
// within it) plus a read/write key. owner_user_id is left empty so findForUser's 1:1 stays intact.
func buildAppSpec(slug, name, dsn string) provision.StackSpec {
	display := strings.TrimSpace(name)
	if display == "" {
		display = slug
	}
	return provision.StackSpec{
		Tenant: slug, Name: display, Plan: "free",
		Engines: []provision.EngineSpec{{
			Engine: "postgresql", Name: "app", ConnectionString: dsn, Isolation: "shared_rls",
		}},
		Keys: []provision.KeySpec{{Name: slug + "-key", Scopes: []string{"read", "write"}}},
	}
}

// mountID returns the provisioned mount's id (the dbId the query path addresses), "" if absent.
func mountID(res provision.ReconcileResult) string {
	for _, r := range res.Resources {
		if r.Kind == "mount" {
			return r.ID
		}
	}
	return ""
}

// appResponse is the 201 body: the app's tenant slug, its db id + query path, and (when freshly
// minted) the cleartext API key — returned ONCE.
func appResponse(slug string, res provision.ReconcileResult) map[string]any {
	dbID := mountID(res)
	out := map[string]any{
		"tenant":    slug,
		"db_id":     dbID,
		"status":    res.Outcome,
		"kong_path": "/query/v1/" + dbID,
	}
	if res.APIKey != nil {
		out["api_key"] = res.APIKey.Key
	}
	return out
}
