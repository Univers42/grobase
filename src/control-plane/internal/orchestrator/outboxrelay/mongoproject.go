/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mongoproject.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:51 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

import (
	"context"
	"fmt"

	"go.mongodb.org/mongo-driver/bson"
)

func (m *mongoProjector) available() bool { return m != nil && m.db != nil }

// projectOrder upserts the orders_view projection for an `order` aggregate —
// the Go port of OutboxRelayService.project.
func (m *mongoProjector) projectOrder(ctx context.Context, e *outboxEvent) error {
	filter, update := m.orderProjection(e)
	if err := m.db.updateOne(ctx, ordersViewCollection, filter, update, true); err != nil {
		return fmt.Errorf("orders_view upsert: %w", err)
	}
	return nil
}

// dispatchMongo applies a saga mongodb-target event (upsert/delete) — the Go
// port of SagaCoordinatorService.dispatchMongo. A non-object saga payload yields
// no projection (parity with the Node objectPayload guard that returns early when
// the payload is not an object).
func (m *mongoProjector) dispatchMongo(ctx context.Context, e *outboxEvent) error {
	coll := e.TargetResource
	if coll == "" {
		coll = e.Aggregate
	}
	if objectJSON(e.Payload) == nil {
		return nil
	}
	if e.Op == "delete" {
		if err := m.db.deleteOne(ctx, coll, bson.M{"_id": e.AggregateID}); err != nil {
			return fmt.Errorf("mongo dispatch delete %s: %w", coll, err)
		}
		return nil
	}
	filter, update := m.sagaProjection(e)
	if err := m.db.updateOne(ctx, coll, filter, update, true); err != nil {
		return fmt.Errorf("mongo dispatch upsert %s: %w", coll, err)
	}
	return nil
}

// close disconnects the client (called on relay shutdown).
func (m *mongoProjector) close(ctx context.Context) {
	if m != nil && m.client != nil {
		_ = m.client.Disconnect(ctx)
	}
}
