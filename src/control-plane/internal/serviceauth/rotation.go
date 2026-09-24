/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rotation.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/25 10:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/25 10:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package serviceauth

import (
	"log/slog"
	"net/http"
	"sync/atomic"
)

const (
	previousAcceptedMetric = "baas_service_token_previous_accepted_total"
	previousAcceptedHelp   = "Service requests authenticated by INTERNAL_SERVICE_TOKEN_PREV (rotation window open)."
	previousAcceptedMsg    = "previous service token accepted — rotation window open; clear INTERNAL_SERVICE_TOKEN_PREV once peers are rolled"
)

// CounterSink is the metrics seam a RotationNotice bumps; it matches
// observability.Metrics.IncCounter so the process metrics value plugs in as-is.
type CounterSink interface {
	IncCounter(name, help, labelKey, labelVal string)
}

// RotationNotice makes an open token-rotation window visible: every request
// accepted under the PREVIOUS token bumps baas_service_token_previous_accepted_total,
// and the first one per notice logs ONE warning. It never logs a header value
// or either token. A nil *RotationNotice is a valid no-op.
type RotationNotice struct {
	log    *slog.Logger
	sink   CounterSink
	warned atomic.Bool
}

// NewRotationNotice builds the notice at the composition root. log may be nil
// (no warning); sink may be nil (no counter).
func NewRotationNotice(log *slog.Logger, sink CounterSink) *RotationNotice {
	return &RotationNotice{log: log, sink: sink}
}

// Observe records one verification outcome. Only MatchedPrevious has an
// effect; MatchedCurrent/NoMatch return immediately with zero allocations.
func (n *RotationNotice) Observe(m Match) {
	if n == nil || m != MatchedPrevious {
		return
	}
	if n.sink != nil {
		n.sink.IncCounter(previousAcceptedMetric, previousAcceptedHelp, "", "")
	}
	if n.log != nil && n.warned.CompareAndSwap(false, true) {
		n.log.Warn(previousAcceptedMsg)
	}
}

// Accept is Verify followed by Observe: it reports whether the request carries
// a valid current-or-previous service token, signalling a previous-token hit.
func (n *RotationNotice) Accept(r *http.Request, expected string) bool {
	m := Verify(r, expected)
	n.Observe(m)
	return m != NoMatch
}
