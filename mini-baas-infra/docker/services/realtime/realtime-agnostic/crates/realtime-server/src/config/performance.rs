/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   performance.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Performance tuning configuration.

use serde::{Deserialize, Serialize};

/// Performance tuning knobs.
///
/// All fields have sensible defaults for typical workloads.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PerformanceConfig {
    /// Send queue capacity per connection.
    #[serde(default = "default_send_queue")]
    pub send_queue_capacity: usize,

    /// Number of fan-out worker tasks.
    #[serde(default = "default_fanout_workers")]
    pub fanout_workers: usize,

    /// Dispatch channel capacity.
    #[serde(default = "default_dispatch_capacity")]
    pub dispatch_channel_capacity: usize,
}

impl Default for PerformanceConfig {
    fn default() -> Self {
        Self {
            send_queue_capacity: default_send_queue(),
            fanout_workers: default_fanout_workers(),
            dispatch_channel_capacity: default_dispatch_capacity(),
        }
    }
}

const fn default_send_queue() -> usize {
    256
}

fn default_fanout_workers() -> usize {
    num_cpus()
}

const fn default_dispatch_capacity() -> usize {
    65536
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(std::num::NonZero::get)
        .unwrap_or(4)
}
