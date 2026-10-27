/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   track_budget.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/27 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/27 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Per-connection budget for TRACK/UNTRACK frames.
//!
//! Every accepted TRACK re-publishes the whole member list to every subscriber
//! of the topic, so one client looping TRACK costs O(subscribers) frames per
//! frame it sends. Subscribe-only collab tokens can TRACK (the `can_track`
//! opt-in), which made this a reader-reachable amplifier; the devil's C1
//! (`presence-track-claim-verdict.md`) required a bound before deploy.
//!
//! Integer milli-tokens: a burst of 10, refilled at one frame per second. A
//! collab client sends TRACK on join and on a rename/avatar change only.

use std::time::Instant;

const BURST_MILLI: u64 = 10_000;
const COST_MILLI: u64 = 1_000;

/// Caveat: per connection, not per user — a client that opens N sockets gets
/// N budgets. The connection cap bounds N; a per-user budget needs shared state.
#[derive(Debug)]
pub(super) struct TrackBudget {
    milli: u64,
    at: Option<Instant>,
}

impl Default for TrackBudget {
    fn default() -> Self {
        Self {
            milli: BURST_MILLI,
            at: None,
        }
    }
}

impl TrackBudget {
    /// Spend one frame's worth; `false` means the frame is dropped.
    pub(super) fn take(&mut self, now: Instant) -> bool {
        if let Some(at) = self.at {
            let elapsed =
                u64::try_from(now.saturating_duration_since(at).as_millis()).unwrap_or(u64::MAX);
            self.milli = self.milli.saturating_add(elapsed).min(BURST_MILLI);
        }
        self.at = Some(now);
        if self.milli < COST_MILLI {
            return false;
        }
        self.milli -= COST_MILLI;
        true
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn a_burst_passes_then_the_flood_is_dropped() {
        let mut budget = TrackBudget::default();
        let t0 = Instant::now();
        let passed = (0..1_000).filter(|_| budget.take(t0)).count();
        assert_eq!(passed, 10);
    }

    #[test]
    fn the_budget_refills_at_one_frame_per_second_up_to_the_burst() {
        let mut budget = TrackBudget::default();
        let t0 = Instant::now();
        while budget.take(t0) {}
        assert!(!budget.take(t0 + Duration::from_millis(999)));
        assert!(budget.take(t0 + Duration::from_millis(1_000)));
        let later = t0 + Duration::from_secs(3_600);
        assert_eq!((0..100).filter(|_| budget.take(later)).count(), 10);
    }
}
