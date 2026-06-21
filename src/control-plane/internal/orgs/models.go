/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:13 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package orgs implements the Track-D D1 organizations / teams / members /
// invites / RBAC layer — the keystone control-plane layer BETWEEN a human and a
// project(=tenant).
//
// THE LOAD-BEARING CONSTRAINT (D-026): org-scoping lives ENTIRELY in the control
// plane. It NEVER enters RequestIdentity, the RLS GUCs (app.current_tenant_id /
// app.current_user_id), or the data plane in ANY way. Orgs sit ABOVE
// tenants(=projects); a tenant still resolves + isolates EXACTLY as today. So
// per-request isolation + SHARE_POOLS (24,887 tenants -> 1 pool) stay byte-
// untouched. The org RBAC matrix gates CONTROL-PLANE routes only; the call an
// org-scoped provision authorizes is the EXISTING reconciler, unchanged.
//
// This package owns:
//   - public.orgs        CRUD (slug + name + plan + status + metadata)
//   - public.org_members membership (role per (org,user)) + the RBAC matrix
//   - public.org_invites email invite issue (sha256-hashed token) -> accept
//   - org-scoped project provisioning (wraps internal/provision.Reconciler)
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when ORG_MODEL_ENABLED is
// truthy. When OFF (the default) Mount is never called, so none of the /v1/orgs*
// routes exist, no orgs/org_members/org_invites row is ever written, and
// tenants.org_id stays NULL — byte-identical to today.
package orgs

import (
	"fmt"
	"regexp"
)

// orgsErr is the package's const-error type: a sentinel is a typed string
// constant, so errors.Is / %w wrapping still work (equal value+type == equal
// error) with no package-level var.
type orgsErr string

func (e orgsErr) Error() string { return string(e) }

const (
	// ErrNotFound is returned when an org / member / invite row does not exist.
	ErrNotFound orgsErr = "org not found"
	// ErrConflict is returned on a uniqueness violation (slug, or an outstanding
	// invite for the same (org,email)).
	ErrConflict orgsErr = "org already exists"
	// ErrForbidden is the load-bearing reject: the caller's org role lacks the
	// capability for the requested control-plane action.
	ErrForbidden orgsErr = "forbidden"
	// ErrLastOwner guards the break-glass anchor: an org must always retain at
	// least one owner, so removing/demoting the sole owner is refused (409).
	ErrLastOwner orgsErr = "cannot remove the last owner"
	// ErrInviteInvalid covers a wrong/replayed/expired/already-consumed invite
	// token (mapped to 401/410/409 by the handler depending on the cause).
	ErrInviteInvalid orgsErr = "invite token invalid"
	// ErrInviteExpired is a present-but-expired invite (mapped to 410 Gone).
	ErrInviteExpired orgsErr = "invite token expired"
	// ErrInviteConsumed is an already-accepted/revoked invite (mapped to 409).
	ErrInviteConsumed orgsErr = "invite already consumed"
)

// slugPattern mirrors the DB CHECK on orgs.slug (same charset as tenants.slug).
const slugPattern = `^[a-z0-9][a-z0-9_-]{1,62}$`

// Org is the public projection of public.orgs.
type Org struct {
	ID        string         `json:"id"`
	Slug      string         `json:"slug"`
	Name      string         `json:"name"`
	Plan      string         `json:"plan"`
	Status    string         `json:"status"`
	Metadata  map[string]any `json:"metadata"`
	CreatedBy *string        `json:"created_by,omitempty"`
	CreatedAt string         `json:"created_at"`
	UpdatedAt string         `json:"updated_at"`
}

// CreateOrgRequest is the POST /v1/orgs body. The creator (resolved from the
// JWT) becomes the org's first member with role=owner, atomically.
type CreateOrgRequest struct {
	Slug     string         `json:"slug"`
	Name     string         `json:"name"`
	Plan     string         `json:"plan"`
	Metadata map[string]any `json:"metadata"`
}

// Validate enforces the same constraints as the DB CHECK.
func (r CreateOrgRequest) Validate() error {
	// perf: regex compiled per call — validation path, API-rate not per-query.
	if !regexp.MustCompile(slugPattern).MatchString(r.Slug) {
		return fmt.Errorf(`slug must match ^[a-z0-9][a-z0-9_-]{1,62}$`)
	}
	if r.Name == "" {
		return fmt.Errorf("name is required")
	}
	return nil
}

// UpdateOrgRequest is the PATCH /v1/orgs/{orgId} body (name + metadata only;
// plan/status changes are billing-gated and handled separately).
type UpdateOrgRequest struct {
	Name     *string        `json:"name"`
	Metadata map[string]any `json:"metadata"`
}

// Member is the public projection of public.org_members.
type Member struct {
	OrgID     string  `json:"org_id"`
	UserID    string  `json:"user_id"`
	Role      string  `json:"role"`
	InvitedBy *string `json:"invited_by,omitempty"`
	CreatedAt string  `json:"created_at"`
}

// SetRoleRequest is the PATCH /v1/orgs/{orgId}/members/{userId} body.
type SetRoleRequest struct {
	Role string `json:"role"`
}

// InviteRequest is the POST /v1/orgs/{orgId}/invites body.
type InviteRequest struct {
	Email string `json:"email"`
	Role  string `json:"role"`
}

// Validate checks the invite shape: a non-empty email and a known role.
func (r InviteRequest) Validate() error {
	if r.Email == "" {
		return fmt.Errorf("email is required")
	}
	if r.Role != "" && !validRole(r.Role) {
		return fmt.Errorf("role must be one of owner|admin|developer|billing|viewer")
	}
	return nil
}

// Invite is the REDACTED projection of public.org_invites — it NEVER carries the
// token (cleartext or hash). The cleartext token is returned exactly ONCE, in
// IssueInviteResponse, at issue time.
type Invite struct {
	ID         string  `json:"id"`
	OrgID      string  `json:"org_id"`
	Email      string  `json:"email"`
	Role       string  `json:"role"`
	Status     string  `json:"status"`
	InvitedBy  string  `json:"invited_by"`
	ExpiresAt  string  `json:"expires_at"`
	CreatedAt  string  `json:"created_at"`
	AcceptedBy *string `json:"accepted_by,omitempty"`
}

// IssueInviteResponse returns the cleartext invite token ONCE (emailed to the
// invitee). Subsequent reads (GET invites) only expose the redacted Invite.
type IssueInviteResponse struct {
	Invite
	Token string `json:"token"`
}

// AcceptInviteRequest is the POST /v1/orgs/invites/accept body.
type AcceptInviteRequest struct {
	Token string `json:"token"`
}

// CreateProjectRequest is the POST /v1/orgs/{orgId}/projects body — the SAME
// declarative shape as tenants.ProvisionRequest (it is converted into a
// provision.StackSpec by the existing Compile()). It is declared here so the orgs
// package owns its own request shape; the provision handler delegates to the
// EXISTING reconciler verbatim.
type CreateProjectRequest struct {
	Tenant          string         `json:"tenant"` // slug
	Name            string         `json:"name"`
	Plan            string         `json:"plan"`
	OwnerUserID     string         `json:"owner_user_id"`
	DefaultRoleName string         `json:"default_role_name"`
	DefaultKeyName  string         `json:"default_key_name"`
	SeedRoles       bool           `json:"seed_roles"`
	Mounts          []ProjectMount `json:"mounts"`
}

// ProjectMount is one data mount in a CreateProjectRequest (engine + name + DSN).
type ProjectMount struct {
	Engine           string `json:"engine"`
	Name             string `json:"name"`
	ConnectionString string `json:"connection_string"`
	Isolation        string `json:"isolation"`
}
