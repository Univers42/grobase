package outboxrelay

import "encoding/json"

// outboxEvent mirrors the OutboxEventRow the Node relay selects. Nullable text
// columns are flattened to "" (matching the Node `?? ''` coalescing on the wire).
type outboxEvent struct {
	ID                  string
	Aggregate           string
	AggregateID         string
	EventType           string
	Payload             json.RawMessage
	RequestID           string
	ActorID             string
	Attempts            int
	TargetEngine        string
	TargetResource      string
	Op                  string
	CompensationPayload json.RawMessage
	IdempotencyKey      string
}

// payloadObject reproduces OutboxRelayService.payload: a JSON object is returned
// as-is; anything else (array, scalar, null) is wrapped as {value: <payload>}.
func payloadObject(raw json.RawMessage) map[string]any {
	var m map[string]any
	if len(raw) > 0 && json.Unmarshal(raw, &m) == nil && m != nil {
		return m
	}
	var v any
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &v)
	}
	return map[string]any{"value": v}
}

// nextFailureStatus reproduces markFailed's transition: attempts+1, and 'dead'
// once the cap is reached (else 'failed'). dead=true triggers compensation.
func nextFailureStatus(attempts, maxAttempts int) (status string, dead bool) {
	if attempts+1 >= maxAttempts {
		return "dead", true
	}
	return "failed", false
}

// publishedDedupeKey is the Redis key guarding a double XADD for one event.
func publishedDedupeKey(id string) string { return "outbox-relay:published:" + id }

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
