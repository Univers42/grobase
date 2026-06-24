/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   resources.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import (
	"context"
	"regexp"
)

// isUUID gates owner_user_id before it is cast to ::uuid for a role assignment,
// so a non-UUID owner is skipped cleanly (matches tenants uuid semantics).
func isUUID(s string) bool {
	// perf: regex compiled per call — provisioning path (API-rate, not hot).
	uuidRe := regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	return uuidRe.MatchString(s)
}

// reconcileTenant find-or-creates the tenant row. On create it threads the
// requested billing plan (default "free") so a provision asking for e.g. `pro`
// actually lands a pro tenant — without this the plan field was silently
// dropped and every tenant defaulted to free, which is why the scale experiment
// had to disable PACKAGE_ENFORCEMENT to register non-sqlite mounts.
func (rc *Reconciler) reconcileTenant(ctx context.Context, res *ReconcileResult, d DesiredState, out ResourceResult) ResourceResult {
	info, exists, err := rc.Tenants.GetTenant(ctx, d.Slug)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if exists {
		res.Tenant = info
		out.Action, out.Status, out.ID = string(ActionNoOp), StatusExists, info.Slug
		return out
	}
	created, err := rc.Tenants.CreateTenant(ctx, d.Slug, d.Name, d.OwnerUser, d.Plan)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	res.Tenant = created
	out.Action, out.Status, out.ID = string(ActionCreate), StatusCreated, created.Slug
	return out
}

// reconcileKey find-or-issues the tenant API key. Idempotent: when an active
// key by that name already exists it is a no-op — a live secret is never
// re-minted.
func (rc *Reconciler) reconcileKey(ctx context.Context, res *ReconcileResult, spec StackSpec, r Resource, out ResourceResult) ResourceResult {
	k := r.Key3
	has, err := rc.Tenants.ActiveKeyExists(ctx, spec.Tenant, k.Name)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if has {
		out.Action, out.Status, out.Detail = string(ActionNoOp), StatusExists, k.Name
		return out
	}
	issued, err := rc.Tenants.IssueAPIKey(ctx, spec.Tenant, k)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if res.APIKey == nil {
		ki := issued
		res.APIKey = &ki
	}
	out.Action, out.Status, out.ID, out.Detail = string(ActionCreate), StatusCreated, issued.ID, k.Name
	return out
}

// roleCtx carries the inputs for reconcileRole: the spec, the resource, the
// partial result, and the shared blocked/roleIDByKey maps.
type roleCtx struct {
	spec        StackSpec
	r           Resource
	out         ResourceResult
	blocked     map[string]bool
	roleIDByKey map[string]string
}

// reconcileRole ensures the slug-namespaced role and records its DB id. It then
// assigns the role to the owner only when OwnerUserID is a UUID (mirrors prior
// seed semantics). Any failure blocks the role's dependent policy steps.
func (rc *Reconciler) reconcileRole(ctx context.Context, rcx roleCtx) ResourceResult {
	spec, r, out, blocked, roleIDByKey := rcx.spec, rcx.r, rcx.out, rcx.blocked, rcx.roleIDByKey
	roleID, created, err := rc.Perm.EnsureRole(ctx, spec.Tenant, r.Role)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		blocked[r.Key] = true
		return out
	}
	roleIDByKey[r.Key] = roleID
	out.ID = roleID
	out.Detail = NamespacedRoleName(r.Key)

	if isUUID(spec.OwnerUserID) {
		if aerr := rc.Perm.AssignRole(ctx, spec.OwnerUserID, NamespacedRoleName(r.Key)); aerr != nil {
			out.Status, out.Error = StatusError, aerr.Error()
			blocked[r.Key] = true
			return out
		}
	}
	if created {
		out.Action, out.Status = string(ActionCreate), StatusCreated
	} else {
		out.Action, out.Status = string(ActionNoOp), StatusExists
	}
	return out
}

func (rc *Reconciler) reconcilePolicy(ctx context.Context, r Resource, out ResourceResult, roleID string) ResourceResult {
	created, err := rc.Perm.EnsurePolicy(ctx, roleID, r.Policy)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if created {
		out.Action, out.Status = string(ActionCreate), StatusCreated
	} else {
		out.Action, out.Status = string(ActionNoOp), StatusExists
	}
	return out
}

// classify folds per-resource statuses into the overall outcome. Only a failed
// TENANT step is fatal (5xx). Any other non-converged status (error, blocked,
