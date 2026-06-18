/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sequence.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 11:13:21 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 13:05:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Per-topic monotonically increasing sequence number generator.
//!
//! Each topic gets its own independent counter. Sequence numbers start
//! at 1 and increment atomically (using `AtomicU64` with `SeqCst` ordering)
//! so they are safe to call from multiple tasks concurrently.
//!
//! Clients use sequence numbers for gap detection and reconnection
//! catch-up (`resume_from` in subscription options).

use dashmap::DashMap;
use smol_str::SmolStr;
use std::sync::atomic::{AtomicU64, Ordering};

/// Per-topic monotonically increasing sequence generator.
///
/// Thread-safe, lock-free. Uses [`DashMap`] for the topic-to-counter
/// map and [`AtomicU64`] for each counter.
///
/// # Examples
///
/// ```
/// use realtime_engine::SequenceGenerator;
/// let gen = SequenceGenerator::new();
/// assert_eq!(gen.next("orders/created"), 1);
/// assert_eq!(gen.next("orders/created"), 2);
/// assert_eq!(gen.next("users/updated"), 1); // independent counter
/// ```
pub struct SequenceGenerator {
    sequences: DashMap<SmolStr, AtomicU64>,
}

impl SequenceGenerator {
    /// Create a new generator with no topics.
    #[must_use]
    pub fn new() -> Self {
        Self {
            sequences: DashMap::new(),
        }
    }

    /// Atomically increment and return the next sequence number for a topic.
    ///
    /// Creates the counter on first access (starting at 0, so the first
    /// returned value is 1).
    #[must_use]
    pub fn next(&self, topic: &str) -> u64 {
        let key = SmolStr::new(topic);
        self.sequences
            .entry(key)
            .or_insert_with(|| AtomicU64::new(0))
            .fetch_add(1, Ordering::SeqCst)
            + 1
    }

    /// Read the current sequence number for a topic without incrementing.
    ///
    /// Returns 0 if the topic has never been seen.
    #[must_use]
    pub fn current(&self, topic: &str) -> u64 {
        let key = SmolStr::new(topic);
        self.sequences
            .get(&key)
            .map_or(0, |v| v.load(Ordering::SeqCst))
    }
}

impl Default for SequenceGenerator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sequence_monotonic() {
        let gen = SequenceGenerator::new();
        let s1 = gen.next("orders/created");
        let s2 = gen.next("orders/created");
        let s3 = gen.next("orders/created");
        assert_eq!(s1, 1);
        assert_eq!(s2, 2);
        assert_eq!(s3, 3);
    }

    #[test]
    fn test_sequence_per_topic() {
        let gen = SequenceGenerator::new();
        let s1 = gen.next("orders/created");
        let s2 = gen.next("users/updated");
        assert_eq!(s1, 1);
        assert_eq!(s2, 1);
    }

    #[test]
    fn test_sequence_current() {
        let gen = SequenceGenerator::new();
        assert_eq!(gen.current("none"), 0);
        let _ = gen.next("test");
        assert_eq!(gen.current("test"), 1);
    }
}
