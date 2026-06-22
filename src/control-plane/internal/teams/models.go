/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:22 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:24 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package teams implements the Track-D RBAC hierarchy that sits inside an org:
// teams, team membership, project-role grants (User→Project and Team→Project), the
// effective-permission resolver, and short-lived non-escalating scoped tokens.
//
// THE LOAD-BEARING CONSTRAINT (inherited from orgs / D-026): this is CONTROL-PLANE
// authorization only. It NEVER enters RequestIdentity, the RLS GUCs, or the data
// plane. Project roles gate *who may manage a project's RBAC*; the data-plane ABAC
// PDP (unchanged) governs *what a project's data requests may do*. Two planes.
//
// FLAG-GATED OFF = PARITY: the /v1/orgs/{id}/teams|grants|tokens routes mount ONLY
// when RBAC_HIERARCHY_ENABLED is truthy (⟹ ORG_MODEL_ENABLED). OFF ⇒ no routes, no
// rows written here — byte-identical to today.
package teams

import (
	"fmt"
	"regexp"
)

// teamsErr is the package's const-error type (a typed string constant — errors.Is
// works, no package-level var).
type teamsErr string

func (e teamsErr) Error() string { return string(e) }

const (
	// ErrNotFound — a team / grant / token row does not exist (404).
	ErrNotFound teamsErr = "not found"
	// ErrForbidden — the caller's role lacks the capability (403).
	ErrForbidden teamsErr = "forbidden"
	// ErrEscalation — a token's role exceeds the issuer's effective role (403).
	ErrEscalation teamsErr = "token role exceeds the issuer's effective role"
	// ErrConflict — a uniqueness violation (e.g. duplicate team slug) (409).
	ErrConflict teamsErr = "already exists"
	// ErrBadRole — an unknown project role on a grant/token (400).
	ErrBadRole teamsErr = "project_role must be one of owner|admin|writer|reader"
	// ErrBadEnv — a grant's env_id does not belong to the project (400).
	ErrBadEnv teamsErr = "env_id does not belong to the project"
)

// ProjectRole is a project-level role, ordered owner > admin > writer > reader.
type ProjectRole string

const (
	RoleReader ProjectRole = "reader"
	RoleWriter ProjectRole = "writer"
	RoleAdmin  ProjectRole = "admin"
	RoleOwner  ProjectRole = "owner"
)

// rank orders project roles by privilege (higher = more powerful). Unknown ⇒ -1.
// The effective-permission resolver MAXes by this — NEVER by lexical SQL ORDER BY,
// since owner|admin|writer|reader do not sort by privilege alphabetically.
func rank(r ProjectRole) int {
	switch r {
	case RoleReader:
		return 0
	case RoleWriter:
		return 1
	case RoleAdmin:
		return 2
	case RoleOwner:
		return 3
	default:
		return -1
	}
}

// validProjectRole reports whether r is one of the four known project roles.
func validProjectRole(r ProjectRole) bool { return rank(r) >= 0 }

// slugPattern mirrors the DB CHECK on teams.slug (same charset as orgs.slug).
const slugPattern = `^[a-z0-9][a-z0-9_-]{1,62}$`

// Team is the public projection of public.teams.
type Team struct {
	ID        string         `json:"id"`
	OrgID     string         `json:"org_id"`
	Slug      string         `json:"slug"`
	Name      string         `json:"name"`
	Metadata  map[string]any `json:"metadata"`
	CreatedBy *string        `json:"created_by,omitempty"`
	CreatedAt string         `json:"created_at"`
	UpdatedAt string         `json:"updated_at"`
}

// TeamMember is the public projection of public.team_members.
type TeamMember struct {
	TeamID    string `json:"team_id"`
	UserID    string `json:"user_id"`
	TeamRole  string `json:"team_role"`
	CreatedAt string `json:"created_at"`
}

// ProjectGrant is the public projection of public.project_grants.
type ProjectGrant struct {
	ID          string      `json:"id"`
	ProjectID   string      `json:"project_id"`
	OrgID       string      `json:"org_id"`
	EnvID       *string     `json:"env_id,omitempty"`
	GranteeKind string      `json:"grantee_kind"`
	GranteeID   string      `json:"grantee_id"`
	ProjectRole ProjectRole `json:"project_role"`
	GrantedBy   string      `json:"granted_by"`
	GrantedAt   string      `json:"granted_at"`
	ExpiresAt   *string     `json:"expires_at,omitempty"`
	Source      string      `json:"source"`
}

// RBACToken is the REDACTED projection of public.rbac_tokens (never the secret).
type RBACToken struct {
	ID           string      `json:"id"`
	TokenPrefix  string      `json:"token_prefix"`
	IssuerUserID string      `json:"issuer_user_id"`
	ScopeKind    string      `json:"scope_kind"`
	ScopeID      string      `json:"scope_id"`
	OrgID        string      `json:"org_id"`
	ProjectRole  ProjectRole `json:"project_role"`
	CreatedAt    string      `json:"created_at"`
	ExpiresAt    string      `json:"expires_at"`
}

// CreateTeamRequest is the POST /v1/orgs/{orgId}/teams body.
type CreateTeamRequest struct {
	Slug     string         `json:"slug"`
	Name     string         `json:"name"`
	Metadata map[string]any `json:"metadata"`
}

// Validate enforces the same constraints as the DB CHECK.
func (r CreateTeamRequest) Validate() error {
	if !regexp.MustCompile(slugPattern).MatchString(r.Slug) {
		return fmt.Errorf(`slug must match %s`, slugPattern)
	}
	if r.Name == "" {
		return fmt.Errorf("name is required")
	}
	return nil
}

// UpdateTeamRequest is the PATCH /v1/orgs/{orgId}/teams/{teamId} body.
type UpdateTeamRequest struct {
	Name     *string        `json:"name"`
	Metadata map[string]any `json:"metadata"`
}

// AddTeamMemberRequest is the POST /v1/orgs/{orgId}/teams/{teamId}/members body.
type AddTeamMemberRequest struct {
	UserID   string `json:"user_id"`
	TeamRole string `json:"team_role"`
}

// GrantRequest is the POST /v1/orgs/{orgId}/projects/{projectId}/grants body.
type GrantRequest struct {
	GranteeKind string      `json:"grantee_kind"` // user | team | group
	GranteeID   string      `json:"grantee_id"`
	ProjectRole ProjectRole `json:"project_role"`
	EnvID       string      `json:"env_id"`     // optional; "" = project-wide (all environments)
	ExpiresAt   string      `json:"expires_at"` // optional RFC3339; "" = never
}

// TokenCreateRequest is the POST /v1/orgs/{orgId}/tokens body.
type TokenCreateRequest struct {
	ProjectRole ProjectRole `json:"project_role"`
	ScopeKind   string      `json:"scope_kind"` // org | project
	ScopeID     string      `json:"scope_id"`   // org id or project(=tenant) id
	TTLSeconds  int         `json:"ttl_seconds"`
}

// TokenCreateResponse returns the cleartext token ONCE, at mint time.
type TokenCreateResponse struct {
	RBACToken
	Token string `json:"token"`
}
