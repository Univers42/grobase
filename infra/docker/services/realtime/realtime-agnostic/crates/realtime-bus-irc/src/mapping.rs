//! Topic <-> IRC channel mapping.
//!
//! Topics in the gateway look like `"<namespace>/<room>"` (e.g. `chat/general`)
//! and map to IRC channels `"#<room>"` (e.g. `#general`). Only the configured
//! namespace is bridged; other topics are ignored by the IRC bus.

/// Convert a gateway topic into an IRC channel name, if it belongs to the
/// bridged namespace.
///
/// Returns `None` when the topic is outside the namespace (and therefore not
/// an IRC channel).
#[must_use]
pub fn topic_to_channel(topic: &str, namespace: &str) -> Option<String> {
    let prefix = format!("{namespace}/");
    topic.strip_prefix(&prefix).map(|room| {
        if room.starts_with('#') {
            room.to_string()
        } else {
            format!("#{room}")
        }
    })
}

/// Convert an IRC channel name into a gateway topic in the bridged namespace.
#[must_use]
pub fn channel_to_topic(channel: &str, namespace: &str) -> String {
    let room = channel.trim_start_matches('#');
    format!("{namespace}/{room}")
}

#[cfg(test)]
mod tests {
    use super::{channel_to_topic, topic_to_channel};

    #[test]
    fn topic_in_namespace_maps_to_channel() {
        assert_eq!(
            topic_to_channel("chat/general", "chat"),
            Some("#general".to_string())
        );
    }

    #[test]
    fn topic_outside_namespace_is_ignored() {
        assert_eq!(topic_to_channel("orders/created", "chat"), None);
    }

    #[test]
    fn channel_maps_back_to_topic() {
        assert_eq!(channel_to_topic("#general", "chat"), "chat/general");
    }

    #[test]
    fn round_trip_is_stable() {
        let ch = topic_to_channel("chat/dev", "chat").unwrap_or_default();
        assert_eq!(channel_to_topic(&ch, "chat"), "chat/dev");
    }
}
