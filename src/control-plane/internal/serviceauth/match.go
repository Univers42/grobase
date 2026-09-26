/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   match.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/25 10:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/25 10:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package serviceauth

import "net/http"

// Match reports which configured service token authenticated a request.
// NoMatch is the zero value, so an unset Match never reads as accepted.
type Match uint8

const (
	// NoMatch means neither the current nor the previous token verified.
	NoMatch Match = iota
	// MatchedCurrent means the current token verified (it wins when both do).
	MatchedCurrent
	// MatchedPrevious means ONLY INTERNAL_SERVICE_TOKEN_PREV verified — the
	// caller is still on a rotated-out token and the rotation window is open.
	MatchedPrevious
)

// Verify authenticates an internal service-to-service request and reports
// which token matched. static mode (default): constant-time X-Service-Token
// compare. hmac mode: a valid X-Service-Auth signature within
// ±SERVICE_AUTH_SKEW_SECS (default 120); r.Body is read and RESTORED.
//
// During a rotation window (INTERNAL_SERVICE_TOKEN_PREV non-empty) both arms
// are always evaluated (no short-circuit, so timing does not leak which key
// matched) and the decision is made afterwards: current wins over previous.
// An empty expected token is always NoMatch.
func Verify(r *http.Request, expected string) Match {
	if expected == "" {
		return NoMatch
	}
	prev := prevServiceToken()
	if !ServiceAuthHMAC() {
		return verifyStaticToken(r, expected, prev)
	}
	return verifyHMAC(r, expected, prev)
}

// pickMatch folds the two already-evaluated arm results into a Match, with the
// current token taking precedence over the previous one.
func pickMatch(curOK, prevOK bool) Match {
	switch {
	case curOK:
		return MatchedCurrent
	case prevOK:
		return MatchedPrevious
	default:
		return NoMatch
	}
}
