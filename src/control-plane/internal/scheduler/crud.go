/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   crud.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:54:40 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:54:41 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package scheduler

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// Create inserts a schedule under the caller's tenant scope. next_run is set to
// now() so a freshly-created schedule fires on the next scheduler tick.
func (s *Service) Create(ctx context.Context, tenantID string, req CreateRequest) (ScheduleRow, error) {
	enabled, timeoutMs, payload := req.defaults()
	var row ScheduleRow
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		r := tx.QueryRow(ctx, `
			INSERT INTO public.function_schedules
			       (tenant_id, name, function_name, schedule_expr, payload, enabled, timeout_ms, next_run)
			VALUES ($1,$2,$3,$4,$5::jsonb,$6,$7, now())
			RETURNING id::text, tenant_id, name, function_name, schedule_expr, payload::text,
			          enabled, timeout_ms,
			          COALESCE(last_run::text,''), next_run::text,
			          COALESCE(last_status,''), created_at::text, updated_at::text`,
			tenantID, req.Name, req.FunctionName, req.ScheduleExpr, payload, enabled, timeoutMs)
		return scanSchedule(r, &row)
	})
	if err != nil {
		if pg.IsUniqueViolation(err) {
			return ScheduleRow{}, ErrConflict
		}
		return ScheduleRow{}, err
	}
	return row, nil
}

// Delete removes a schedule.
func (s *Service) Delete(ctx context.Context, tenantID, id string) error {
	return s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM public.function_schedules WHERE id = $1`, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// Update mutates the fields present in the request.
func (s *Service) Update(ctx context.Context, tenantID, id string, req UpdateRequest) (ScheduleRow, error) {
	payload, err := req.normalize()
	if err != nil {
		return ScheduleRow{}, err
	}
	var row ScheduleRow
	err = s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		r := tx.QueryRow(ctx, updateReturning,
			id, req.FunctionName, req.ScheduleExpr, payload, req.Enabled, req.TimeoutMs)
		if e := scanSchedule(r, &row); e != nil {
			if errors.Is(e, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return e
		}
		return nil
	})
	return row, err
}

const updateReturning = `
	UPDATE public.function_schedules
	   SET function_name = COALESCE($2, function_name),
	       schedule_expr = COALESCE($3, schedule_expr),
	       payload       = COALESCE($4::jsonb, payload),
	       enabled       = COALESCE($5, enabled),
	       timeout_ms    = COALESCE($6, timeout_ms),
	       updated_at    = now()
	 WHERE id = $1
	 RETURNING id::text, tenant_id, name, function_name, schedule_expr, payload::text,
	           enabled, timeout_ms,
	           COALESCE(last_run::text,''), next_run::text,
	           COALESCE(last_status,''), created_at::text, updated_at::text`
