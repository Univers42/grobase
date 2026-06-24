/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   resources_mount.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:40 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import (
	"context"
	"strings"
)

// reconcileMount registers a data mount via the adapter-registry. An isolation
// model the data plane cannot realise (e.g. db_per_tenant) is surfaced
// explicitly as StatusUnsupported — NOT a silent skip — and blocks the
// dependent schema step. A RegisterMount status other than "created" (i.e.
// "exists") maps to a no-op result.
func (rc *Reconciler) reconcileMount(ctx context.Context, spec StackSpec, r Resource, out ResourceResult, blocked map[string]bool) ResourceResult {
	e := r.Engine
	if !D().SupportedMountIsolation[e.Isolation] {
		out.Status, out.Detail = StatusUnsupported, e.Isolation
		blocked[r.Key] = true
		return out
	}
	if rc.Mounts == nil {
		return blockMount(out, blocked, r.Key, "mount client not configured")
	}
	id, status, err := rc.Mounts.RegisterMount(ctx, spec.Tenant, e)
	if err != nil {
		return blockMount(out, blocked, r.Key, err.Error())
	}
	out.ID = id
	switch status {
	case "created":
		out.Action, out.Status = string(ActionCreate), StatusCreated
	default:
		out.Action, out.Status = string(ActionNoOp), StatusExists
	}
	return out
}

// blockMount stamps a mount-step error and blocks the dependent schema step.
func blockMount(out ResourceResult, blocked map[string]bool, key, msg string) ResourceResult {
	out.Status, out.Error = StatusError, msg
	blocked[key] = true
	return out
}

// reconcileSchema ensures a per-tenant Postgres schema (schema_per_tenant is
// postgresql-only). Because CREATE SCHEMA IF NOT EXISTS is a no-op when present
// and the data plane does not distinguish created vs existed, the result is
// always reported as ensured (exists).
func (rc *Reconciler) reconcileSchema(ctx context.Context, spec StackSpec, r Resource, out ResourceResult) ResourceResult {
	e := r.Engine
	if !strings.EqualFold(e.Engine, "postgresql") {
		out.Status, out.Error = StatusError, "schema_per_tenant only supported for postgresql mounts"
		return out
	}
	if rc.Schemas == nil {
		out.Status, out.Error = StatusError, "schema client not configured"
		return out
	}
	schema, err := rc.Schemas.EnsureSchema(ctx, spec.Tenant, e)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	out.Action, out.Status, out.Detail = string(ActionNoOp), StatusExists, schema
	return out
}
