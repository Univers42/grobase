/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   event.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:47 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:48 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

import "encoding/json"

// outboxEvent mirrors the OutboxEventRow the Node relay selects. Nullable text
// columns are flattened to "" (matching the Node `?? ”` coalescing on the wire).
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
