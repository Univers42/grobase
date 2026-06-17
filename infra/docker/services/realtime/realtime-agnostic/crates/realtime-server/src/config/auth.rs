/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Authentication configuration.

use serde::{Deserialize, Serialize};

/// Authentication backend selection.
///
/// - `NoAuth` — accepts all tokens (development only).
/// - `Jwt` — validates HMAC-SHA256 / RSA tokens.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AuthConfig {
    #[serde(rename = "none")]
    #[default]
    NoAuth,
    #[serde(rename = "jwt")]
    Jwt {
        secret: String,
        #[serde(default)]
        issuer: Option<String>,
        #[serde(default)]
        audience: Option<String>,
    },
}

/// Manual Debug: the server logs its config at startup (`Auth: {:?}`), and the
/// derived impl printed the JWT secret in plain text into container logs.
impl std::fmt::Debug for AuthConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoAuth => write!(f, "NoAuth"),
            Self::Jwt { issuer, audience, .. } => f
                .debug_struct("Jwt")
                .field("secret", &"<redacted>")
                .field("issuer", issuer)
                .field("audience", audience)
                .finish(),
        }
    }
}
