package abuseguard

import (
	"context"
	"fmt"
)

// upsertSuspendSQL flips a tenant's suspended state, creating the row if absent.
// suspended_at/reason are set on suspend and left as-is on unsuspend (an audit
// breadcrumb of the last suspension).
const upsertSuspendSQL = `
INSERT INTO public.tenant_safety (tenant_id, suspended, suspended_reason, suspended_at, updated_at)
VALUES ($1, $2, $3, CASE WHEN $2 THEN now() ELSE NULL END, now())
ON CONFLICT (tenant_id) DO UPDATE
   SET suspended        = EXCLUDED.suspended,
       suspended_reason = CASE WHEN EXCLUDED.suspended THEN EXCLUDED.suspended_reason ELSE public.tenant_safety.suspended_reason END,
       suspended_at     = CASE WHEN EXCLUDED.suspended THEN now() ELSE public.tenant_safety.suspended_at END,
       updated_at       = now()`

// setSuspended persists the suspend state and updates the Redis suspended set (add
// on suspend, remove on unsuspend) so the data plane's snapshot converges. The DB
// write is the source of truth; a Redis failure is logged, not fatal (the next
// republish, or the data plane's TTL-bounded snapshot refresh, heals it).
func (g *Guard) setSuspended(ctx context.Context, tenantID string, suspended bool, reason string) error {
	if err := g.db.AdminExec(ctx, upsertSuspendSQL, tenantID, suspended, reason); err != nil {
		return fmt.Errorf("abuse: persist suspend(%v): %w", suspended, err)
	}
	g.publishOne(ctx, tenantID, suspended)
	return nil
}

// publishOne adds/removes one tenant from the suspended set. No-op when Redis is
// unconfigured (Init logged that; admission still works off the DB).
func (g *Guard) publishOne(ctx context.Context, tenantID string, suspended bool) {
	if g.rdb == nil {
		return
	}
	var err error
	if suspended {
		err = g.rdb.SAdd(ctx, suspendedSet, tenantID).Err()
	} else {
		err = g.rdb.SRem(ctx, suspendedSet, tenantID).Err()
	}
	if err != nil {
		g.log.Warn("abuse: suspended-set update failed (DB is source of truth; will heal on republish)",
			"tenant", tenantID, "suspended", suspended, "err", err)
	}
}

const selectSuspendedSQL = `SELECT tenant_id FROM public.tenant_safety WHERE suspended = true`

// republishSuspended rebuilds the Redis suspended set from the DB (the source of
// truth) atomically: build a staging set, RENAME onto the live key, PEXPIRE so a
// crashed guard cannot leave a stale set suspending forever. An empty result DELETEs
// the live key (fail-OPEN: no suspensions). Same atomic-publish shape as the
// quota/spend guards. Called at Init and reusable by an admin "resync" path.
func (g *Guard) republishSuspended(ctx context.Context) error {
	if g.rdb == nil {
		return nil
	}
	ids, err := g.readSuspendedIDs(ctx)
	if err != nil {
		return err
	}
	return g.publishSuspendedSet(ctx, ids)
}

// readSuspendedIDs reads every suspended tenant id from the DB (the source of truth).
func (g *Guard) readSuspendedIDs(ctx context.Context) ([]string, error) {
	rows, err := g.db.AdminQuery(ctx, selectSuspendedSQL)
	if err != nil {
		return nil, fmt.Errorf("abuse: read suspended: %w", err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// publishSuspendedSet atomically rebuilds the Redis suspended set from ids: stage,
// RENAME onto the live key (an empty result DELETEs it — fail-OPEN, no suspensions).
func (g *Guard) publishSuspendedSet(ctx context.Context, ids []string) error {
	const staging = suspendedSet + ":staging"
	pipe := g.rdb.TxPipeline()
	pipe.Del(ctx, staging)
	if len(ids) == 0 {
		pipe.Del(ctx, suspendedSet)
		_, err := pipe.Exec(ctx)
		return err
	}
	members := make([]any, len(ids))
	for i, id := range ids {
		members[i] = id
	}
	pipe.SAdd(ctx, staging, members...)
	pipe.Rename(ctx, staging, suspendedSet)
	_, err := pipe.Exec(ctx)
	return err
}
