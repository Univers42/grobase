/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:41 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:55:43 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package scim implements the Track-D D2b SCIM 2.0 provisioning surface
// (RFC 7644 — System for Cross-domain Identity Management). An enterprise IdP
// (Okta / Entra / OneLogin) drives user lifecycle into Grobase over a bearer
// credential: POST/GET/PUT/PATCH/DELETE /scim/v2/Users. SCIM provisions ORG
// MEMBERS — the humans above a project — so every provisioning op delegates to
// the EXISTING internal/orgs service (Add/Remove member); SCIM owns only the
// bearer-token store, the SCIM resource <-> member mapping, and the SCIM JSON
// shapes.
//
// THE LOAD-BEARING CONSTRAINT (D-026): SCIM is a CONTROL-PLANE operation. It
// NEVER enters RequestIdentity, the RLS GUCs (app.current_tenant_id /
// request.tenant_id), or the data plane. The bearer token resolves to a
// tenant_id (+ a concrete org_id); that tenant binding is the per-tenant wall —
// a T1 token can never read or modify a SCIM resource provisioned under T2.
// Per-request isolation + SHARE_POOLS (24,887 tenants -> 1 pool) stay untouched.
//
// SECURITY (kernel rule #7): a SCIM bearer token is HIGH-ENTROPY, so it is hashed
// with a FAST hash (sha256), NOT a password hash — the SAME discipline as
// tenant_api_keys.key_hash and org_invites.token_hash. The cleartext is returned
// ONCE at issue time and never persisted.
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when SCIM_ENABLED is truthy.
// When OFF (the default) Mount is never called, so none of the /scim/v2/* routes
// exist (404), no scim_tokens/scim_users row is ever written, and
// org_members.active stays true for every row — byte-identical to today.
package scim

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// scimErr is the package's const-error type: a sentinel is a typed string
// constant, so errors.Is / %w wrapping still work (equal value+type == equal
// error) with no package-level var.
type scimErr string

func (e scimErr) Error() string { return string(e) }

const (
	// ErrTokenInvalid is the load-bearing reject: a missing/unknown/revoked SCIM
	// bearer token. The handler maps it to 401 (RFC 7644 §3.12).
	ErrTokenInvalid scimErr = "scim bearer token invalid"
	// ErrNotFound is returned when a SCIM resource (user) does not exist within
	// the bound tenant. Mapped to 404 by the handler.
	ErrNotFound scimErr = "scim resource not found"
	// ErrNoOrg is returned when a provisioning op runs under a token with no
	// org_id bound (provisioning needs a concrete org). Mapped to 400.
	ErrNoOrg scimErr = "scim token is not bound to an org"
)

// TokenBinding is what VerifyToken resolves: the tenant (+ optional org) a SCIM
// bearer token authorizes. TenantID is the per-tenant wall; OrgID is the org
// provisioning lands on. TokenID identifies the row (for Touch).
type TokenBinding struct {
	TokenID  string
	TenantID string
	OrgID    string
}

// store is the SCIM persistence layer. It speaks SQL over the admin pool
// (BYPASSRLS service_role) and ALWAYS binds tenant_id in its WHERE clauses
// (defense-in-depth behind the RLS policies in migration 054).
type store struct {
	db *pg.Postgres
}

func newStore(db *pg.Postgres) *store { return &store{db: db} }

// hashToken is the fast, non-reversible lookup token for a cleartext SCIM bearer
// (sha256 lower-hex). A high-entropy token → fast hash (kernel rule #7); the
// cleartext is never stored or logged. Mirrors tenants.keyHash / the
// org_invites token discipline.
func hashToken(cleartext string) string {
	sum := sha256.Sum256([]byte(cleartext))
	return hex.EncodeToString(sum[:])
}

// newCleartextToken mints a 256-bit high-entropy bearer token (base64url, no
// padding). The returned string is shown to the IdP admin ONCE; only its sha256
// is persisted.
func newCleartextToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "scim_" + base64.RawURLEncoding.EncodeToString(b), nil
}
