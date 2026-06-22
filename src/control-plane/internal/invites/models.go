/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package invites — generalized, scope-agnostic invitations for the NEW RBAC scopes
// (team | group | project). Org invites keep their own system (internal/orgs, 043); this
// package adds team/group/project invites + invite-driven pending signup on the unified
// `invites` table (080). CONTROL-PLANE ONLY (never enters the RLS GUCs / data plane);
// flag-gated by INVITES_ENABLED. Token discipline mirrors orgs (256-bit token, store only
// sha256, 7-day TTL, single-use atomic accept).
package invites

// inviteErr is the package's const-error type (errors.Is works, no package-level var).
type inviteErr string

func (e inviteErr) Error() string { return string(e) }

const (
	// ErrInvalid — no invite matches the presented token (401).
	ErrInvalid inviteErr = "invalid invite token"
	// ErrExpired — the invite is past its TTL (410).
	ErrExpired inviteErr = "invite expired"
	// ErrConsumed — the invite was already accepted/revoked (409).
	ErrConsumed inviteErr = "invite already used"
	// ErrConflict — an outstanding pending invite for the same (scope, email) (409).
	ErrConflict inviteErr = "a pending invite already exists for this email"
	// ErrNotFound — the invite / scope does not exist (404).
	ErrNotFound inviteErr = "not found"
	// ErrBadScope — an unknown scope_kind or a role invalid for the scope (400).
	ErrBadScope inviteErr = "scope_kind must be one of team|group|project, with a valid role"
)

// inviteTokenBytes is the raw entropy of an invite token (256 bits); inviteTokenPrefix tags
// the cleartext for humans/logs (the whole token is hashed); defaultInviteTTLHours = 7 days.
const (
	inviteTokenBytes      = 32
	inviteTokenPrefix     = "mbi_"
	defaultInviteTTLHours = 168
)

// Invite is the public (redacted — never the token) projection of public.invites.
type Invite struct {
	ID         string  `json:"id"`
	ScopeKind  string  `json:"scope_kind"`
	ScopeID    string  `json:"scope_id"`
	OrgID      string  `json:"org_id"`
	Email      string  `json:"email"`
	Role       string  `json:"role"`
	Status     string  `json:"status"`
	InvitedBy  string  `json:"invited_by"`
	ExpiresAt  string  `json:"expires_at"`
	CreatedAt  string  `json:"created_at"`
	AcceptedBy *string `json:"accepted_by,omitempty"`
}

// IssueInviteRequest is the POST .../invites body.
type IssueInviteRequest struct {
	Email string `json:"email"`
	Role  string `json:"role"`
}

// IssueInviteResponse returns the cleartext token ONCE, at issue time.
type IssueInviteResponse struct {
	Invite
	Token string `json:"token"`
}

// validRoleForScope reports whether role is valid for scope_kind (group ignores role).
func validRoleForScope(scopeKind, role string) bool {
	switch scopeKind {
	case "team":
		return role == "manager" || role == "member"
	case "group":
		return true
	case "project":
		return role == "owner" || role == "admin" || role == "writer" || role == "reader"
	default:
		return false
	}
}
