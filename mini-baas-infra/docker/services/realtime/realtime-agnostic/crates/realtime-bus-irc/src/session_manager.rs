//! Per-user IRC session pool — the "hybrid" identity model.
//!
//! Each platform user that publishes gets their own IRC connection (NICK
//! derived from their handle), so they appear individually in IRC with real
//! presence (they JOIN the channels they speak in) and their messages carry
//! their own nick rather than a shared service identity. Sessions open lazily
//! on first publish and are reaped after a period of inactivity.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use dashmap::DashMap;
use realtime_core::types::EventEnvelope;
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info};

use crate::client::{run_client, SessionConfig};
use crate::identity::to_irc_nick;

/// A live per-user IRC session: a write channel plus tracking state.
struct UserHandle {
    cmd_tx: mpsc::Sender<String>,
    joined: Mutex<HashSet<String>>,
    last_active: Mutex<Instant>,
}

/// Owns and lazily creates per-user IRC sessions.
pub struct SessionManager {
    host: String,
    port: u16,
    password: String,
    user: String,
    realname: String,
    namespace: String,
    nick_max: usize,
    inbound: broadcast::Sender<EventEnvelope>,
    users: DashMap<String, Arc<UserHandle>>,
}

impl SessionManager {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        host: String,
        port: u16,
        password: String,
        user: String,
        realname: String,
        namespace: String,
        nick_max: usize,
        inbound: broadcast::Sender<EventEnvelope>,
    ) -> Self {
        Self {
            host,
            port,
            password,
            user,
            realname,
            namespace,
            nick_max,
            inbound,
            users: DashMap::new(),
        }
    }

    /// Publish `text` to `channel` as the given user, opening their session and
    /// joining the channel on first use.
    pub async fn publish_as_user(&self, user_id: &str, handle: &str, channel: &str, text: &str) {
        let user = self.get_or_create(user_id, handle);

        // Join the channel once per session (lock released before awaiting).
        let need_join = {
            let mut joined = user.joined.lock().unwrap_or_else(PoisonError::into_inner);
            if joined.contains(channel) {
                false
            } else {
                joined.insert(channel.to_string());
                true
            }
        };
        if need_join && user.cmd_tx.send(format!("JOIN {channel}")).await.is_err() {
            self.drop_user(user_id);
            return;
        }

        if user
            .cmd_tx
            .send(format!("PRIVMSG {channel} :{text}"))
            .await
            .is_err()
        {
            self.drop_user(user_id);
            return;
        }
        *user.last_active.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
    }

    fn get_or_create(&self, user_id: &str, handle: &str) -> Arc<UserHandle> {
        if let Some(existing) = self.users.get(user_id) {
            return existing.clone();
        }
        let nick = to_irc_nick(user_id, handle, self.nick_max);
        let (cmd_tx, cmd_rx) = mpsc::channel::<String>(256);
        let session = SessionConfig {
            host: self.host.clone(),
            port: self.port,
            password: self.password.clone(),
            nick,
            user: self.user.clone(),
            realname: self.realname.clone(),
            channels: Vec::new(),
            namespace: self.namespace.clone(),
            forward_inbound: false, // service connection is the sole inbound source
        };
        let inbound = self.inbound.clone();
        let entry = self
            .users
            .entry(user_id.to_string())
            .or_insert_with(|| {
                tokio::spawn(run_client(session, cmd_rx, inbound));
                Arc::new(UserHandle {
                    cmd_tx,
                    joined: Mutex::new(HashSet::new()),
                    last_active: Mutex::new(Instant::now()),
                })
            })
            .clone();
        info!(%user_id, "opened per-user IRC session");
        entry
    }

    fn drop_user(&self, user_id: &str) {
        self.users.remove(user_id);
        debug!(%user_id, "dropped per-user IRC session");
    }

    /// QUIT and remove sessions idle longer than `max_idle`.
    pub async fn reap_idle(&self, max_idle: Duration) {
        let now = Instant::now();
        let mut stale = Vec::new();
        for kv in &self.users {
            let last = *kv.value().last_active.lock().unwrap_or_else(PoisonError::into_inner);
            if now.duration_since(last) > max_idle {
                stale.push(kv.key().clone());
            }
        }
        for key in stale {
            if let Some((_, handle)) = self.users.remove(&key) {
                let _ = handle.cmd_tx.send("QUIT :idle".to_string()).await;
                debug!(user_id = %key, "reaped idle per-user IRC session");
            }
        }
    }
}
