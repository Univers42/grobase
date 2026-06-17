/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   transport.rs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use async_trait::async_trait;
use std::net::SocketAddr;

use crate::error::Result;
use crate::protocol::{ClientMessage, ServerMessage};
use crate::types::ConnectionMeta;

/// Transport server that accepts incoming client connections.
///
/// # Purpose
/// This trait exists so alternative transports (raw TCP, QUIC) can
/// be plugged in alongside the default Axum WebSocket server.
#[async_trait]
pub trait TransportServer: Send + Sync + 'static {
    /// Bind the server to a network address and begin listening.
    async fn bind(&self, addr: SocketAddr) -> Result<()>;

    /// Accept the next incoming connection.
    async fn accept(&self) -> Result<(Box<dyn TransportConnection>, ConnectionMeta)>;
}

/// A single bidirectional client connection (transport-agnostic).
///
/// # Purpose
/// Represents one WebSocket (or future TCP/QUIC) connection. The
/// gateway splits each into a reader task and a writer channel.
#[async_trait]
pub trait TransportConnection: Send + Sync {
    /// Receive the next message from the client.
    async fn recv_message(&mut self) -> Result<Option<ClientMessage>>;

    /// Send a message to the client.
    async fn send_message(&mut self, msg: ServerMessage) -> Result<()>;

    /// Gracefully close the connection.
    async fn close(&mut self, code: u16, reason: &str) -> Result<()>;

    /// Return the peer's socket address.
    fn peer_addr(&self) -> SocketAddr;
}
