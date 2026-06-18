/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   topic_path.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use serde::{Deserialize, Serialize};
use smol_str::SmolStr;
use std::fmt;

/// Logical topic path used for event routing.
///
/// # Purpose
/// Topics are hierarchical paths separated by `/`, e.g., `"orders/created"`.
/// The first segment is the namespace (used for authorization).
///
/// # Example
/// ```
/// use realtime_core::TopicPath;
/// let topic = TopicPath::new("orders/created");
/// assert_eq!(topic.namespace(), "orders");
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TopicPath(pub SmolStr);

impl TopicPath {
    /// Create a new topic path from a string slice.
    ///
    /// # Arguments
    /// * `s` — The topic path string, e.g. `"orders/created"`.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn new(s: &str) -> Self {
        Self(SmolStr::new(s))
    }

    /// Return the topic path as a string slice.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    /// Return the namespace (first path segment before `/`).
    ///
    /// # Purpose
    /// The namespace drives authorization: clients subscribe only
    /// within their allowed namespaces.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn namespace(&self) -> &str {
        self.0.split('/').next().unwrap_or("")
    }

    /// Return the event-type segment (second path segment).
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn event_type_part(&self) -> &str {
        self.0.split('/').nth(1).unwrap_or("")
    }
}

impl fmt::Display for TopicPath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}
