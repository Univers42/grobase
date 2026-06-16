/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lib.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 11:13:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 23:40:36 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! # realtime-engine
//!
//! The routing brain of the Realtime-Agnostic event engine.
//!
//! This crate contains the subscription registry, event router, sequence generator,
//! bitmap-based filter index, and the producer registry. It decides which events
//! go to which connections.
//!
//! ## Key Components
//!
//! - [`SubscriptionRegistry`] — Multi-indexed in-memory registry mapping topics to connections.
//!   Uses [`DashMap`](dashmap::DashMap) for lock-free concurrent reads.
//! - [`EventRouter`] — Accepts events from the bus, evaluates subscriptions, dispatches to connections.
//! - [`SequenceGenerator`] — Per-topic monotonically increasing sequence counter (lock-free via `AtomicU64`).
//! - [`FilterIndex`] — Bitmap-based inverted index using [Roaring Bitmaps](roaring::RoaringBitmap)
//!   for O(log N) filter evaluation at scale.
//! - [`ProducerRegistry`] — Runtime registry of database adapter factories.
//!
//! ## Architecture
//!
//! ```text
//! EventBus → EventRouter → SubscriptionRegistry.lookup_matches()
//!                        → FilterIndex.evaluate() (bitmap)
//!                        → SequenceGenerator.next()
//!                        → dispatch_tx → FanOutWorkerPool
//! ```

pub mod filter_index;
pub mod presence;
pub mod producer_registry;
pub mod registry;
pub mod router;
pub mod sequence;

pub use filter_index::limits::FilterIndexLimits;
pub use filter_index::stats::StatsSnapshot;
pub use filter_index::{DispatchSlot, FilterIndex};
pub use presence::PresenceTracker;
pub use producer_registry::ProducerRegistry;
pub use registry::SubscriptionRegistry;
pub use router::{DispatchStatsSnapshot, EventRouter};
pub use sequence::SequenceGenerator;
