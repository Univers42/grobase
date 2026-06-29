/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rbac.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:27 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:29 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package orgs

// rbac.go — the SINGLE source of truth for the org RBAC capability matrix
// (kernel rule #8). Five org roles gate CONTROL-PLANE routes only. The matrix is
// a static table consulted by requireCapability (handler.go), which mirrors
// tenants.requireServiceToken / tenants.selfServe.requireScope.
//
// This is a control-plane decision: the matrix is checked BEFORE a handler ever
// calls the reconciler or the tenant service, and the call it ultimately
// authorizes (Reconcile(StackSpec)) is byte-identical to the call /v1/provision
// makes today. The data-plane ABAC PDP (internal/provision/permission_engine.go)
// is NEVER consulted for an org decision and is NEVER modified — org RBAC governs
// *who may ask the control plane to act*; the ABAC PDP governs *what the resulting
// project's data requests may do*. Two planes, two questions, no overlap.

// Role is an org membership role.
type Role string

const (
	RoleOwner     Role = "owner"
	RoleAdmin     Role = "admin"
	RoleDeveloper Role = "developer"
	RoleBilling   Role = "billing"
	RoleViewer    Role = "viewer"
)

// Capability names — one per gated control-plane action.
const (
	CapOrgRead       = "org:read"        // view org, members, projects
	CapOrgUpdate     = "org:update"      // rename, metadata
	CapOrgDelete     = "org:delete"      // soft-delete the org
	CapMemberInvite  = "member:invite"   // issue / revoke an invite
	CapMemberRemove  = "member:remove"   // remove a member
	CapMemberRoleSet = "member:role:set" // change a member's role
	CapProjectCreate = "project:create"  // provision a project (the org-scoped reconcile)
	CapProjectRead   = "project:read"    // list/read projects
	CapProjectDelete = "project:delete"  // delete a project
	CapProjectKeys   = "project:keys"    // issue/revoke project API keys
	CapBillingRead   = "billing:read"    // usage rollup, invoices
	CapBillingManage = "billing:manage"  // change org plan, payment method

	// RBAC-hierarchy capabilities (RBAC_HIERARCHY_ENABLED, internal/teams).
	CapTeamCreate = "team:create"   // create a team in the org
	CapTeamUpdate = "team:update"   // rename / re-tag a team
	CapTeamDelete = "team:delete"   // delete a team
	CapTeamMember = "team:member"   // add/remove a team member (or a team manager)
	CapProjGrant  = "project:grant" // grant/revoke a project role (user or team)
	CapTokenIssue = "token:issue"   // mint/revoke a scoped, non-escalating RBAC token
)

// Can reports whether role holds the named capability. Unknown role or unknown
// capability → false (deny by default). The matrix is a switch (no global map):
// each case lists exactly the roles the OLD capabilities table granted, so the
// truth table is byte-identical.
func Can(role Role, cap string) bool {
	switch cap {
	case CapOrgRead, CapProjectRead:
		return role == RoleOwner || role == RoleAdmin || role == RoleDeveloper ||
			role == RoleBilling || role == RoleViewer
	case CapOrgUpdate, CapMemberInvite, CapMemberRemove, CapMemberRoleSet, CapProjectDelete,
		CapTeamCreate, CapTeamUpdate, CapTeamDelete, CapTeamMember, CapProjGrant:
		return role == RoleOwner || role == RoleAdmin
	case CapProjectCreate, CapProjectKeys, CapTokenIssue:
		return role == RoleOwner || role == RoleAdmin || role == RoleDeveloper
	case CapOrgDelete:
		return role == RoleOwner
	case CapBillingRead:
		return role == RoleOwner || role == RoleAdmin || role == RoleBilling
	case CapBillingManage:
		return role == RoleOwner || role == RoleBilling
	default:
		return false
	}
}

// validRole reports whether s is one of the five known org roles.
func validRole(s string) bool {
	switch Role(s) {
	case RoleOwner, RoleAdmin, RoleDeveloper, RoleBilling, RoleViewer:
		return true
	default:
		return false
	}
}

// canSetRole encodes the admin-vs-owner asymmetry (design footnote ¹): an owner
// may set any role; an admin may set roles UP TO admin but may NOT create or
// demote-from an owner (the owner is the break-glass anchor). actor is the
// caller's role; target is the role being assigned; current is the assignee's
// existing role.
func canSetRole(actor, target, current Role) bool {
	if !Can(actor, CapMemberRoleSet) {
		return false
	}
	if actor == RoleOwner {
		return true
	}
	if target == RoleOwner || current == RoleOwner {
		return false
	}
	return true
}
