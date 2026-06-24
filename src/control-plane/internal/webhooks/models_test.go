/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models_test.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:01:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:01:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

import (
	"testing"
	"time"
)

// TestBackoffJitterBounds locks in the F2 fix: backoff used to be deterministic
// while its doc-comment claimed jitter, so a batch of deliveries that failed
// together retried in lockstep (thundering herd on recovery). Equal jitter must
// keep every sample within [base/2, base] AND actually vary across samples.
func TestBackoffJitterBounds(t *testing.T) {
	for attempt := 1; attempt <= 12; attempt++ {
		base := time.Duration(1<<min(attempt, 9)) * time.Second
		if base > maxBackoff {
			base = maxBackoff
		}
		lo, hi := base/2, base
		seen := map[time.Duration]bool{}
		for i := 0; i < 256; i++ {
			d := backoff(attempt)
			if d < lo || d > hi {
				t.Fatalf("attempt %d: backoff %v outside [%v, %v]", attempt, d, lo, hi)
			}
			seen[d] = true
		}
		if len(seen) < 2 {
			t.Fatalf("attempt %d: backoff produced no jitter (%d distinct in 256 samples)", attempt, len(seen))
		}
	}
}

// TestBackoffClampsAndCaps proves the attempt floor (<=0 → 1) and that even a
// huge attempt never exceeds the 5-minute cap after jitter.
func TestBackoffClampsAndCaps(t *testing.T) {
	for _, a := range []int{-5, 0, 1} {
		if d := backoff(a); d < time.Second || d > 2*time.Second {
			t.Fatalf("attempt %d: %v not in [1s, 2s]", a, d)
		}
	}
	for i := 0; i < 256; i++ {
		if d := backoff(999); d > maxBackoff {
			t.Fatalf("backoff(999)=%v exceeds cap %v", d, maxBackoff)
		}
	}
}
