/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_schema.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:56 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:57 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"errors"
)

// EnsureSchema checks migration 032 has been applied, then idempotently widens
// the plan CHECK constraint to the current package manifest (migration 035 /
// F1) — self-healing at boot, the same pattern adapter-registry uses for the
// tenant_databases isolation CHECK. Migration 005 pinned the constraint at
// ('free','pro','enterprise'), so without this a plan PATCH to a real tier key
// (nano/basic/essential/max) 500s and PACKAGE_ENFORCEMENT cannot be used.
//
// The interior rows.Close() frees the pooled conn before the ALTERs run (the
// deferred Close is then a no-op). The widen is additive + idempotent: existing
// rows (free/pro/enterprise, or NULL) all satisfy the widened set, so the ADD
// never fails on legacy data. Failures are logged, not fatal — a stale
// constraint degrades tiering, it doesn't stop serving.
func (s *Service) EnsureSchema(ctx context.Context) error {
	const q = `SELECT 1 FROM information_schema.tables
	            WHERE table_schema='public' AND table_name='tenants'`
	rows, err := s.db.AdminQuery(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.tenants missing — run migration 032_tenants.sql")
	}
	rows.Close()

	if err := s.db.AdminExec(ctx,
		`ALTER TABLE public.tenants DROP CONSTRAINT IF EXISTS tenants_plan_check`); err != nil {
		s.log.Warn("drop stale tenants_plan_check failed (continuing)", "error", err)
	} else if err := s.db.AdminExec(ctx,
		`ALTER TABLE public.tenants ADD CONSTRAINT tenants_plan_check
		   CHECK (plan IN ('nano','basic','essential','pro','max','free','enterprise'))`); err != nil {
		s.log.Warn("widen tenants_plan_check failed (continuing)", "error", err)
	}
	return nil
}
