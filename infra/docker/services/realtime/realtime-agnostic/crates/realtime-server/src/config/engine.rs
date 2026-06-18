/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engine.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Engine-level configuration (filter index limits, etc.).

use realtime_engine::FilterIndexLimits;
use serde::{Deserialize, Serialize};

/// Engine tuning parameters.
///
/// Currently exposes the [`FilterIndexLimits`] that control cardinality
/// guards on the filter index. All fields default to the same values
/// used by [`FilterIndexLimits::default()`].
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EngineConfig {
    /// Hard caps on the filter index to prevent resource exhaustion.
    #[serde(default)]
    pub limits: FilterIndexLimits,
}
