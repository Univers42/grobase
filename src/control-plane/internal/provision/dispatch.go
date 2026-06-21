/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dispatch.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:05 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import "context"

// acquireSlugLock takes the per-slug advisory lock (one in-flight reconcile per
// slug). With no Locker wired it is a no-op returning a no-op release. ErrBusy is
// returned when the lock is held elsewhere (→ 409).
func (rc *Reconciler) acquireSlugLock(ctx context.Context, slug string) (func(), error) {
	if rc.Lock == nil {
		return func() {}, nil
	}
	release, ok, err := rc.Lock.TryLock(ctx, slug)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, ErrBusy
	}
	return release, nil
}

// applyAll walks the compiled resources in topo order, applying each. blocked
// tracks resource Keys whose prerequisite failed (a dependent of a blocked/failed
// parent is itself blocked); roleIDByKey resolves a policy's parent role to its
// DB id once observed.
func (rc *Reconciler) applyAll(ctx context.Context, spec StackSpec, desired DesiredState) ReconcileResult {
	res := ReconcileResult{Resources: make([]ResourceResult, 0, len(desired.Resources))}
	blocked := map[string]bool{}
	roleIDByKey := map[string]string{}
	for _, r := range desired.Resources {
		out := rc.applyOne(ctx, applyCtx{&res, spec, desired, r, blocked, roleIDByKey})
		res.Resources = append(res.Resources, out)
	}
	return res
}

// blockedFor reports whether a (non-tenant) resource has an unmet prerequisite,
// returning the StatusBlocked result to surface. A dependent of a blocked/failed
// parent is itself blocked (no downstream write).
func blockedFor(r Resource, spec StackSpec, blocked map[string]bool, roleIDByKey map[string]string) (ResourceResult, bool) {
	out := ResourceResult{Kind: kindName(r.Kind), Key: r.Key, Status: StatusBlocked}
	switch r.Kind {
	case KindKey, KindRole, KindMount:
		return out, blocked[TenantKey(spec.Tenant)]
	case KindPolicy:
		return out, blocked[r.RoleRef] || roleIDByKey[r.RoleRef] == ""
	case KindSchema:
		return out, blocked[r.Key2]
	default:
		return out, false
	}
}
