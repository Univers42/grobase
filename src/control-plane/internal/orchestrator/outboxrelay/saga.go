/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   saga.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:50:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

import (
	"context"
	"encoding/json"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

// sagaDispatch routes a saga target event to its engine (parity with
// SagaCoordinatorService.dispatch): mongodb → projector, redis-family → stream,
// none → skip, unsupported → error.
func (s *Service) sagaDispatch(ctx context.Context, e *outboxEvent) error {
	kind, err := sagaTargetKind(e.TargetEngine, e.TargetResource)
	if err != nil {
		return err
	}
	switch kind {
	case "mongo":
		return s.project.dispatchMongo(ctx, e)
	case "stream":
		return s.dispatchStream(ctx, e)
	default:
		return nil
	}
}

// dispatchStream XADDs to `saga.<engine>.<resource>` (parity with dispatchStream).
func (s *Service) dispatchStream(ctx context.Context, e *outboxEvent) error {
	payloadJSON := "{}"
	if len(e.Payload) > 0 {
		payloadJSON = string(e.Payload)
	}
	return s.rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: "saga." + e.TargetEngine + "." + e.TargetResource,
		Values: sagaStreamFields(e, payloadJSON),
	}).Err()
}

// sagaCompensate schedules a compensating outbox event when one is configured
// (parity with SagaCoordinatorService.compensate). Runs on the active tx so the
// compensation is atomic with the dead-letter status update.
func (s *Service) sagaCompensate(ctx context.Context, tx pgx.Tx, e *outboxEvent) error {
	comp := objectJSON(e.CompensationPayload)
	if comp == nil {
		return nil
	}
	_, err := tx.Exec(ctx,
		`INSERT INTO public.outbox_events
		   (aggregate, aggregate_id, event_type, payload, request_id, actor_id, status, saga_state)
		 VALUES ($1, $2, $3, $4::jsonb, $5, $6, 'pending', 'compensating')`,
		e.Aggregate, e.AggregateID, e.EventType+".compensate", string(comp),
		pg.NullableStr(e.RequestID), pg.NullableStr(e.ActorID))
	if err == nil {
		s.log.Warn("scheduled compensation", "event", e.ID)
	}
	return err
}

// objectJSON returns the raw JSON only if it is a JSON object (parity with
// objectPayload: arrays/scalars/null yield no compensation).
func objectJSON(raw json.RawMessage) json.RawMessage {
	var m map[string]any
	if len(raw) > 0 && json.Unmarshal(raw, &m) == nil && m != nil {
		return raw
	}
	return nil
}
