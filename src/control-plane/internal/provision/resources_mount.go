package provision

import (
	"context"
	"strings"
)

func (rc *Reconciler) reconcileMount(ctx context.Context, spec StackSpec, r Resource, out ResourceResult, blocked map[string]bool) ResourceResult {
	e := r.Engine
	if !D().SupportedMountIsolation[e.Isolation] {
		// e.g. db_per_tenant — declared but not realisable here. Surface it
		// explicitly (NOT a silent skip) and block the dependent schema step.
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
	default: // "exists"
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
	// CREATE SCHEMA IF NOT EXISTS is a no-op when present; the data plane does
	// not distinguish created vs existed, so we report it as ensured (exists).
	out.Action, out.Status, out.Detail = string(ActionNoOp), StatusExists, schema
	return out
}
