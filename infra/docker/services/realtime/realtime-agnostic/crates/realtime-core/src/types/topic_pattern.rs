/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   topic_pattern.rs                                   :+:      :+:    :+:   */
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

use super::TopicPath;

/// Topic pattern used when subscribing to events.
///
/// # Purpose
/// Subscriptions match topics in three ways: exact, prefix, or glob.
///
/// | Variant  | Example          | Matches                       |
/// |----------|------------------|-------------------------------|
/// | `Exact`  | `orders/created` | Only `orders/created`         |
/// | `Prefix` | `orders/`        | `orders/created`, etc.        |
/// | `Glob`   | `*/created`      | `orders/created`, etc.        |
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TopicPattern {
    /// Exact match — topic must be identical.
    Exact(TopicPath),
    /// Prefix match — topic must start with this prefix.
    Prefix(SmolStr),
    /// Glob match — `*` = one segment, `**` = all remaining.
    Glob(SmolStr),
}

impl TopicPattern {
    /// Test whether a concrete topic matches this pattern.
    ///
    /// # Arguments
    /// * `topic` — The concrete topic to test.
    ///
    /// # Returns
    /// `true` if the topic matches.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn matches(&self, topic: &TopicPath) -> bool {
        match self {
            Self::Exact(path) => path == topic,
            Self::Prefix(prefix) => topic.as_str().starts_with(prefix.as_str()),
            Self::Glob(pattern) => glob_match(pattern.as_str(), topic.as_str()),
        }
    }

    /// Parse a string into the most appropriate variant.
    ///
    /// # Purpose
    /// Contains `*` → Glob. Ends with `/` → Prefix. Otherwise → Exact.
    ///
    /// # Example
    /// ```
    /// use realtime_core::TopicPattern;
    /// assert!(matches!(TopicPattern::parse("orders/*"), TopicPattern::Glob(_)));
    /// ```
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn parse(s: &str) -> Self {
        if s.contains('*') {
            Self::Glob(SmolStr::new(s))
        } else if s.ends_with('/') {
            Self::Prefix(SmolStr::new(s))
        } else {
            Self::Exact(TopicPath::new(s))
        }
    }

    /// Return the pattern as a string slice.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            Self::Exact(path) => path.as_str(),
            Self::Prefix(s) | Self::Glob(s) => s.as_str(),
        }
    }
}

impl fmt::Display for TopicPattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

// Glob matching: `*` = one segment, `**` = all remaining.
fn glob_match(pattern: &str, topic: &str) -> bool {
    let pat: Vec<&str> = pattern.split('/').collect();
    let parts: Vec<&str> = topic.split('/').collect();

    for (i, p) in pat.iter().enumerate() {
        if *p == "**" {
            return true;
        }
        if i >= parts.len() {
            return false;
        }
        if *p != "*" && *p != parts[i] {
            return false;
        }
    }
    pat.len() == parts.len()
}
