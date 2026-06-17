/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   presence_shared.rs                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! A6/A5 — **cross-node** presence backend (Track-A residual).
//!
//! ## Why this exists
//!
//! The in-process [`PresenceTracker`](realtime_engine::PresenceTracker) is
//! *single-node authoritative*: each server instance only knows the members
//! connected to *itself*. On a multi-node deployment behind a load balancer,
//! a `TRACK` on node A is invisible to a presence query served by node B.
//!
//! [`SharedPresence`] adds a **shared backend** (Redis) the engine does not
//! own: every `TRACK`/`UNTRACK` mirrors the member into a Redis hash keyed by
//! topic, and a presence query reads the *merged* set from Redis — so a member
//! that joined on node A is listed by node B.
//!
//! ## Sub-flag (`REALTIME_PRESENCE_SHARED`, default OFF) = byte-parity
//!
//! When OFF, the gateway never constructs a [`SharedPresence`]
//! (`AppState.presence_shared` is `None`): `TRACK`/`UNTRACK` only touch the
//! local in-process tracker, no Redis connection is opened, and the presence
//! query endpoint answers from the local set exactly as a single node always
//! has. A second node simply does not see the first — today's behaviour,
//! byte-identical. Turning the flag ON is the *only* thing that wires the shared
//! store in.
//!
//! ## Data model (no cross-channel leak by construction)
//!
//! One Redis hash **per topic**: `key = "{prefix}:{topic}"`, `field = conn_id`,
//! `value = serialized PresenceMember`. A member is only ever written under its
//! own topic's key and only ever read back from that same key, so a member in
//! channel X can never surface in a query for channel Y. Entry TTL bounds the
//! key against a crashed node leaking stale members forever.

use std::time::Duration;

use realtime_core::PresenceMember;
use redis::aio::ConnectionManager;
use tokio::sync::OnceCell;
use tracing::warn;

/// Default Redis key namespace for per-topic presence hashes. A topic's set
/// lives at `"{PRESENCE_KEY_PREFIX}:{topic}"`.
const PRESENCE_KEY_PREFIX: &str = "presence";

/// TTL (seconds) refreshed on every write so a crashed node's members do not
/// leak forever. Long enough that a live member is re-asserted by client
/// re-tracks / heartbeats well within it.
const PRESENCE_TTL_SECS: u64 = 120;

/// Redis-backed shared presence store — the cross-node merge backend.
///
/// Constructed ONLY when the `REALTIME_PRESENCE_SHARED` sub-flag is ON; at
/// parity `AppState.presence_shared` is `None` and nothing here is ever reached.
/// The connection is lazy (opened on first use) so an unreachable Redis at boot
/// never blocks startup.
#[derive(Clone)]
pub struct SharedPresence {
    url: String,
    prefix: String,
    conn: std::sync::Arc<OnceCell<ConnectionManager>>,
}

impl SharedPresence {
    /// Build a shared presence store against `url`. The default key prefix
    /// (`presence`) is used; see [`with_prefix`](Self::with_prefix) to override.
    #[must_use]
    pub fn new(url: &str) -> Self {
        Self {
            url: url.to_string(),
            prefix: PRESENCE_KEY_PREFIX.to_string(),
            conn: std::sync::Arc::new(OnceCell::new()),
        }
    }

    /// Override the Redis key prefix (test isolation).
    #[must_use]
    pub fn with_prefix(mut self, prefix: &str) -> Self {
        if !prefix.trim().is_empty() {
            self.prefix = prefix.to_string();
        }
        self
    }

    /// The Redis key for a topic's presence hash. A member is only ever written
    /// to / read from its own topic's key — so channel X can never leak into a
    /// query for channel Y.
    fn key(&self, topic: &str) -> String {
        format!("{}:{}", self.prefix, topic)
    }

    /// Lazily open (and cache) the auto-reconnecting Redis connection.
    async fn conn(&self) -> Option<ConnectionManager> {
        let mgr = self
            .conn
            .get_or_try_init(|| async {
                let client = redis::Client::open(self.url.as_str())?;
                ConnectionManager::new(client).await
            })
            .await;
        match mgr {
            Ok(m) => Some(m.clone()),
            Err(e) => {
                warn!(target: "presence", "shared presence redis connect failed (best-effort): {e}");
                None
            }
        }
    }

    /// Mirror a member into the shared store under `topic`. Best-effort: a Redis
    /// failure is logged and dropped, never panics, never blocks the WS path.
    /// Refreshes the topic key's TTL on every write.
    pub async fn track(&self, topic: &str, member: &PresenceMember) {
        let Some(mut conn) = self.conn().await else {
            return;
        };
        let Ok(value) = serde_json::to_string(member) else {
            return;
        };
        let key = self.key(topic);
        let res: redis::RedisResult<()> = redis::pipe()
            .atomic()
            .cmd("HSET")
            .arg(&key)
            .arg(&member.conn_id)
            .arg(&value)
            .ignore()
            .cmd("EXPIRE")
            .arg(&key)
            .arg(PRESENCE_TTL_SECS)
            .ignore()
            .query_async(&mut conn)
            .await;
        if let Err(e) = res {
            warn!(target: "presence", topic = %topic, "shared presence HSET failed (best-effort): {e}");
        }
    }

    /// Remove a member from the shared store under `topic`. Best-effort. Prunes
    /// the topic key when it becomes empty so a query for an empty topic returns
    /// no members (and the namespace stays bounded).
    pub async fn untrack(&self, topic: &str, conn_id: &str) {
        let Some(mut conn) = self.conn().await else {
            return;
        };
        let key = self.key(topic);
        let res: redis::RedisResult<()> = redis::cmd("HDEL")
            .arg(&key)
            .arg(conn_id)
            .query_async(&mut conn)
            .await;
        if let Err(e) = res {
            warn!(target: "presence", topic = %topic, "shared presence HDEL failed (best-effort): {e}");
            return;
        }
        // Prune an emptied topic key so an empty topic lists nothing.
        let len: redis::RedisResult<u64> =
            redis::cmd("HLEN").arg(&key).query_async(&mut conn).await;
        if matches!(len, Ok(0)) {
            let _: redis::RedisResult<()> =
                redis::cmd("DEL").arg(&key).query_async(&mut conn).await;
        }
    }

    /// The MERGED member set for `topic` across all nodes (reads the topic's
    /// Redis hash). Returns an empty vec when the topic has no members or Redis
    /// is unreachable (best-effort, never panics).
    #[must_use]
    pub async fn members(&self, topic: &str) -> Vec<PresenceMember> {
        let Some(mut conn) = self.conn().await else {
            return Vec::new();
        };
        let key = self.key(topic);
        let vals: redis::RedisResult<Vec<String>> =
            redis::cmd("HVALS").arg(&key).query_async(&mut conn).await;
        match vals {
            Ok(vals) => vals
                .iter()
                .filter_map(|v| serde_json::from_str::<PresenceMember>(v).ok())
                .collect(),
            Err(e) => {
                warn!(target: "presence", topic = %topic, "shared presence HVALS failed (best-effort): {e}");
                Vec::new()
            }
        }
    }

    /// Drop a connection from EVERY topic it joined in the shared store
    /// (disconnect path). Scans the presence namespace and HDELs the conn from
    /// each topic key it appears in, pruning emptied keys. Best-effort.
    pub async fn remove_connection(&self, conn_id: &str) {
        let Some(mut conn) = self.conn().await else {
            return;
        };
        let pattern = format!("{}:*", self.prefix);
        // SCAN (not KEYS) so a large namespace never blocks Redis.
        let mut cursor: u64 = 0;
        loop {
            let scan: redis::RedisResult<(u64, Vec<String>)> = redis::cmd("SCAN")
                .arg(cursor)
                .arg("MATCH")
                .arg(&pattern)
                .arg("COUNT")
                .arg(100)
                .query_async(&mut conn)
                .await;
            let (next, keys) = match scan {
                Ok(v) => v,
                Err(e) => {
                    warn!(target: "presence", "shared presence SCAN failed (best-effort): {e}");
                    return;
                }
            };
            for key in keys {
                let _: redis::RedisResult<()> = redis::cmd("HDEL")
                    .arg(&key)
                    .arg(conn_id)
                    .query_async(&mut conn)
                    .await;
                let len: redis::RedisResult<u64> =
                    redis::cmd("HLEN").arg(&key).query_async(&mut conn).await;
                if matches!(len, Ok(0)) {
                    let _: redis::RedisResult<()> =
                        redis::cmd("DEL").arg(&key).query_async(&mut conn).await;
                }
            }
            cursor = next;
            if cursor == 0 {
                break;
            }
        }
    }

    /// Bounded health probe used at startup (best-effort PING with a short
    /// timeout). Returns `true` when Redis answered, else `false` — the caller
    /// logs but never fails boot on a not-yet-ready Redis.
    pub async fn ping(&self) -> bool {
        let Some(mut conn) = self.conn().await else {
            return false;
        };
        let fut = async {
            let r: redis::RedisResult<String> =
                redis::cmd("PING").query_async(&mut conn).await;
            r
        };
        matches!(
            tokio::time::timeout(Duration::from_secs(2), fut).await,
            Ok(Ok(_))
        )
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn member(conn: &str, user: &str) -> PresenceMember {
        PresenceMember {
            conn_id: conn.to_string(),
            user_id: Some(user.to_string()),
            meta: serde_json::json!({ "color": "blue" }),
        }
    }

    #[test]
    fn key_is_namespaced_per_topic() {
        let sp = SharedPresence::new("redis://127.0.0.1:6379");
        assert_eq!(sp.key("room/1"), "presence:room/1");
        // A second topic gets a DISTINCT key — channel X can never collide with Y.
        assert_ne!(sp.key("room/1"), sp.key("room/2"));
    }

    #[test]
    fn prefix_override_isolates_namespace() {
        let sp = SharedPresence::new("redis://127.0.0.1:6379").with_prefix("m97");
        assert_eq!(sp.key("room/1"), "m97:room/1");
        // A blank prefix is ignored (keeps the default).
        let sp2 = SharedPresence::new("redis://127.0.0.1:6379").with_prefix("  ");
        assert_eq!(sp2.key("room/1"), "presence:room/1");
    }

    #[test]
    fn member_round_trips_through_json() {
        // The value written to / read from Redis is the serialized member, so a
        // round-trip must preserve identity — the cross-node merge depends on it.
        let m = member("c1", "alice");
        let s = serde_json::to_string(&m).expect("serialize");
        let back: PresenceMember = serde_json::from_str(&s).expect("deserialize");
        assert_eq!(back, m);
    }
}
