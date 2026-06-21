/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   relay.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:13 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package github

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

// relay.go — verify the Vercel relay forward. The relay holds ONLY this HMAC secret;
// it cannot mint a token. The header binds the body + a timestamp so a captured
// forward cannot be replayed past the skew window (the serviceauth v1 scheme).

const relaySkewSecs = 300

// verifyRelay checks an `X-Github-Relay: v1.<ts>.<hexsig>` header against `body`.
// sig = HMAC-SHA256(secret, "v1\n<ts>\n<hex(sha256(body))>"). Returns ErrRelayAuth on
// any mismatch or stale timestamp.
func verifyRelay(secret []byte, header string, body []byte, now int64) error {
	parts := strings.SplitN(strings.TrimSpace(header), ".", 3)
	if len(parts) != 3 || parts[0] != "v1" {
		return ErrRelayAuth
	}
	ts, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || abs64(now-ts) > relaySkewSecs {
		return ErrRelayAuth
	}
	bodyHash := sha256.Sum256(body)
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte("v1\n" + parts[1] + "\n" + hex.EncodeToString(bodyHash[:])))
	expected := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(expected), []byte(parts[2])) {
		return ErrRelayAuth
	}
	return nil
}

// abs64 is the absolute value of an int64 (skew comparison).
func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}
