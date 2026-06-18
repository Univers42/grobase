/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bus.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! [`InProcessBus`] struct and [`EventBus`] trait implementation.

use async_trait::async_trait;
use realtime_core::{EventBus, EventBusPublisher, EventBusSubscriber, EventEnvelope, Result};
use tokio::sync::broadcast;
use tracing::info;

use crate::publisher::InProcessPublisher;
use crate::subscriber::InProcessSubscriber;

/// Default channel capacity (65 536 messages).
#[allow(dead_code)]
pub const DEFAULT_CAPACITY: usize = 65536;

/// In-process event bus implementation using tokio broadcast channels.
///
/// All publishers and subscribers share a single `broadcast::Sender`.
/// No external dependencies — suitable for single-node deployment and testing.
pub struct InProcessBus {
    sender: broadcast::Sender<EventEnvelope>,
    _capacity: usize,
}

impl InProcessBus {
    /// Create a new in-process bus with the specified channel capacity.
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        info!(capacity, "In-process event bus created");
        Self {
            sender,
            _capacity: capacity,
        }
    }
}

#[async_trait]
impl EventBus for InProcessBus {
    async fn publisher(&self) -> Result<Box<dyn EventBusPublisher>> {
        Ok(Box::new(InProcessPublisher::new(self.sender.clone())))
    }

    async fn subscriber(&self, _topic_pattern: &str) -> Result<Box<dyn EventBusSubscriber>> {
        let receiver = self.sender.subscribe();
        Ok(Box::new(InProcessSubscriber::new(receiver)))
    }

    async fn health_check(&self) -> Result<()> {
        Ok(())
    }

    async fn shutdown(&self) -> Result<()> {
        info!("In-process event bus shut down");
        Ok(())
    }
}
