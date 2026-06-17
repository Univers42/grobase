/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lib.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! # realtime-auth
//!
//! Authentication and authorization providers for the Realtime-Agnostic engine.
//!
//! Two providers are included:
//!
//! - [`JwtAuthProvider`] — Verifies HS256/HS384/HS512 (or RSA) JWTs. Extracts
//!   subject, namespaces, publish/subscribe permissions from token claims.
//!   Namespace-scoped authorization: clients can only access topics within
//!   their allowed namespaces.
//!
//! - [`NoAuthProvider`] — Accepts any token, returns full-access claims.
//!   Used for development, testing, and the `SyncSpace` demo.
//!
//! ## Custom Auth
//!
//! Implement [`AuthProvider`](realtime_core::AuthProvider) to add `OAuth2`,
//! API key, or any other authentication mechanism.

pub mod jwt;
mod noauth;

pub use jwt::{JwtAuthProvider, JwtConfig};
pub use noauth::NoAuthProvider;
