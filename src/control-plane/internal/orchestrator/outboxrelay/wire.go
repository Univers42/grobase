/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   wire.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:23 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:50:24 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

// streamFields builds the positional XADD field list for `outbox.<aggregate>`,
// in the exact order the Node relay writes them (parity for stream consumers).
func streamFields(e *outboxEvent, payloadJSON string) []any {
	return []any{
		"id", e.ID,
		"aggregate_id", e.AggregateID,
		"event_type", e.EventType,
		"payload", payloadJSON,
		"request_id", e.RequestID,
		"actor_id", e.ActorID,
		"idempotency_key", e.IdempotencyKey,
	}
}

// sagaStreamFields builds the positional XADD field list for a saga target
// stream `saga.<engine>.<resource>`.
func sagaStreamFields(e *outboxEvent, payloadJSON string) []any {
	return []any{
		"id", e.ID,
		"aggregate_id", e.AggregateID,
		"op", e.Op,
		"payload", payloadJSON,
		"request_id", e.RequestID,
		"actor_id", e.ActorID,
		"idempotency_key", e.IdempotencyKey,
	}
}

// realtimeBody builds the realtime /publish payload (parity with publishRealtime).
func realtimeBody(e *outboxEvent) map[string]any {
	idem := e.IdempotencyKey
	if idem == "" {
		idem = e.ID
	}
	var requestID, actorID any
	if e.RequestID != "" {
		requestID = e.RequestID
	}
	if e.ActorID != "" {
		actorID = e.ActorID
	}
	return map[string]any{
		"topic":           "outbox/" + e.Aggregate + "/" + e.EventType,
		"event_type":      e.EventType,
		"idempotency_key": idem,
		"payload": map[string]any{
			"id":           e.ID,
			"aggregate":    e.Aggregate,
			"aggregate_id": e.AggregateID,
			"request_id":   requestID,
			"actor_id":     actorID,
			"data":         payloadObject(e.Payload),
		},
	}
}

// sagaTargetKind classifies a saga target engine: "" (no target → skip), "mongo"
// (projection), "stream" (redis-family stream), or an error for an unsupported
// engine — reproducing SagaCoordinatorService.dispatch's switch.
func sagaTargetKind(engine, resource string) (string, error) {
	if engine == "" || resource == "" {
		return "", nil
	}
	switch engine {
	case "mongodb":
		return "mongo", nil
	case "redis", "cassandra", "elasticsearch", "qdrant", "influx", "http", "jdbc", "neo4j":
		return "stream", nil
	default:
		return "", errUnsupportedEngine(engine)
	}
}
