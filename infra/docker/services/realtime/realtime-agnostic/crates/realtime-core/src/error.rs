/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   error.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 11:11:32 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 23:40:36 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Error types for the Realtime-Agnostic engine.
//!
//! All fallible operations across every crate return [`Result<T>`], which
//! is an alias for `std::result::Result<T, RealtimeError>`. The error enum
//! is designed to map cleanly to HTTP status codes via [`RealtimeError::status_code()`].

use thiserror::Error;

/// Unified error enum used across all Realtime-Agnostic crates.
///
/// Each variant maps to a specific HTTP status code (see [`status_code()`](Self::status_code)),
/// enabling the gateway to translate internal errors into proper HTTP or
/// WebSocket error responses without pattern-matching on strings.
///
/// ## Adding new variants
///
/// 1. Add the variant below with an `#[error("...")]` message.
/// 2. Add a case to [`status_code()`](Self::status_code).
/// 3. The rest of the codebase uses `Result<T>` and `?` propagation.
#[derive(Debug, Error)]
pub enum RealtimeError {
    /// Client provided invalid credentials (HTTP 401).
    #[error("Authentication failed: {0}")]
    AuthFailed(String),

    /// Client lacks permission for the requested operation (HTTP 403).
    #[error("Authorization denied: {0}")]
    AuthorizationDenied(String),

    /// Error creating or managing a subscription (HTTP 400).
    #[error("Subscription error: {0}")]
    SubscriptionError(String),

    /// Error publishing an event (HTTP 500).
    #[error("Publish error: {0}")]
    PublishError(String),

    /// WebSocket or TCP connection error (HTTP 500).
    #[error("Connection error: {0}")]
    ConnectionError(String),

    /// Transport-layer error (HTTP 500).
    #[error("Transport error: {0}")]
    TransportError(String),

    /// Event bus (message broker) error (HTTP 500).
    #[error("Event bus error: {0}")]
    EventBusError(String),

    /// Client-supplied filter expression is invalid (HTTP 400).
    #[error("Filter parse error: {0}")]
    FilterParseError(String),

    /// Event payload exceeds the 64 KB limit (HTTP 413).
    #[error("Payload too large: {size} bytes (max: {max} bytes)")]
    PayloadTooLarge {
        /// Actual payload size in bytes.
        size: usize,
        /// Maximum allowed size (65 536 bytes).
        max: usize,
    },

    /// Topic path is malformed or empty (HTTP 400).
    #[error("Topic invalid: {0}")]
    InvalidTopic(String),

    /// Client is sending too many requests (HTTP 429).
    #[error("Rate limited: retry after {retry_after_ms}ms")]
    RateLimited {
        /// Milliseconds the client should wait before retrying.
        retry_after_ms: u64,
    },

    /// A capacity limit was exceeded (HTTP 429).
    ///
    /// Returned when subscription cardinality, pattern count, or
    /// per-connection limits are hit.
    #[error("Capacity exceeded: {reason}")]
    CapacityExceeded {
        /// Human-readable explanation of which limit was hit.
        reason: String,
    },

    /// Upstream dependency is unavailable (HTTP 503).
    #[error("Service unavailable: {0}")]
    ServiceUnavailable(String),

    /// Catch-all for unexpected internal errors (HTTP 500).
    #[error("Internal error: {0}")]
    Internal(String),

    /// Configuration file or environment variable error (HTTP 500).
    #[error("Configuration error: {0}")]
    ConfigError(String),

    /// Transparent wrapper for `anyhow::Error` (HTTP 500).
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl RealtimeError {
    /// Map this error to the appropriate HTTP status code.
    ///
    /// Used by the REST API and WebSocket handler to set response status.
    ///
    /// | Error variant          | Status code |
    /// |------------------------|-------------|
    /// | `AuthFailed`           | 401         |
    /// | `AuthorizationDenied`  | 403         |
    /// | `PayloadTooLarge`      | 413         |
    /// | `RateLimited`          | 429         |
    /// | `ServiceUnavailable`   | 503         |
    /// | `InvalidTopic` / `FilterParseError` / `SubscriptionError` | 400 |
    /// | Everything else        | 500         |
    #[must_use]
    pub const fn status_code(&self) -> u16 {
        match self {
            Self::AuthFailed(_) => 401,
            Self::AuthorizationDenied(_) => 403,
            Self::PayloadTooLarge { .. } => 413,
            Self::RateLimited { .. } | Self::CapacityExceeded { .. } => 429,
            Self::ServiceUnavailable(_) => 503,
            Self::InvalidTopic(_) | Self::FilterParseError(_) | Self::SubscriptionError(_) => 400,
            _ => 500,
        }
    }
}

/// Convenience alias used throughout every Realtime-Agnostic crate.
pub type Result<T> = std::result::Result<T, RealtimeError>;
