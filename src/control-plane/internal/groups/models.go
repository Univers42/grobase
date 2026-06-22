/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package groups — project-scoped groups (always "<project>'s group"), distinct from teams:
// a team is org-scoped and spans projects, a group's scope is its ONE project (exactly one
// group per project). CONTROL-PLANE ONLY (never enters the RLS GUCs / data plane); flag-gated
// by GROUPS_ENABLED (requires RBAC_HIERARCHY_ENABLED). Mirrors the teams package shape.
package groups

// groupErr is the package's const-error type (errors.Is works, no package-level var).
type groupErr string

func (e groupErr) Error() string { return string(e) }

const (
	// ErrNotFound — a group / member row does not exist (404).
	ErrNotFound groupErr = "not found"
	// ErrConflict — the project already has its group (409).
	ErrConflict groupErr = "already exists"
	// ErrBadReq — a missing required field (400).
	ErrBadReq groupErr = "user_id is required"
)

// Group is the public projection of public.groups. Name is always "<project>'s group".
type Group struct {
	ID        string  `json:"id"`
	ProjectID string  `json:"project_id"`
	OrgID     string  `json:"org_id"`
	Name      string  `json:"name"`
	CreatedBy *string `json:"created_by,omitempty"`
	CreatedAt string  `json:"created_at"`
}

// GroupMember is the public projection of public.group_members.
type GroupMember struct {
	GroupID   string `json:"group_id"`
	UserID    string `json:"user_id"`
	CreatedAt string `json:"created_at"`
}

// AddGroupMemberRequest is the POST /v1/groups/{groupId}/members body.
type AddGroupMemberRequest struct {
	UserID string `json:"user_id"`
}
