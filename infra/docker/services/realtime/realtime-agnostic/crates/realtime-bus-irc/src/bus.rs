//! [`IrcBus`] — an [`EventBus`] backend that bridges the gateway to an IRC
//! server. A shared service connection is the single inbound source and posts
//! platform events; per-user sessions (see [`SessionManager`]) carry each
//! platform user's own messages under their own nick.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use realtime_core::{EventBus, EventBusPublisher, EventBusSubscriber, EventEnvelope, Result};
use tokio::sync::{broadcast, mpsc};
use tracing::info;

use crate::client::{run_client, SessionConfig};
use crate::identity::DEFAULT_NICK_MAX;
use crate::publisher::IrcPublisher;
use crate::session_manager::SessionManager;
use crate::subscriber::IrcSubscriber;
use crate::IrcBusConfig;

/// How often to sweep for idle per-user sessions, and the idle cutoff.
const REAP_INTERVAL: Duration = Duration::from_secs(60);
const USER_IDLE: Duration = Duration::from_secs(300);

/// IRC-backed event bus with a shared service connection + per-user sessions.
pub struct IrcBus {
    cmd_tx: mpsc::Sender<String>,
    inbound: broadcast::Sender<EventEnvelope>,
    namespace: String,
    manager: Arc<SessionManager>,
}

impl IrcBus {
    /// Connect to the configured IRC server and start the session tasks.
    #[must_use]
    pub fn new(config: IrcBusConfig) -> Self {
        let (cmd_tx, cmd_rx) = mpsc::channel::<String>(1024);
        let (inbound, _) = broadcast::channel::<EventEnvelope>(config.capacity);

        // Shared service connection: the sole inbound source; posts platform
        // events and joins the configured channels.
        let session = SessionConfig {
            host: config.host.clone(),
            port: config.port,
            password: config.password.clone(),
            nick: config.nick.clone(),
            user: config.user.clone(),
            realname: config.realname.clone(),
            channels: config.channels.clone(),
            namespace: config.namespace.clone(),
            forward_inbound: true,
        };
        let inbound_tx = inbound.clone();
        tokio::spawn(async move {
            run_client(session, cmd_rx, inbound_tx).await;
        });

        // Per-user session pool (write-only sessions, no inbound duplication).
        let manager = Arc::new(SessionManager::new(
            config.host,
            config.port,
            config.password,
            config.user,
            config.realname,
            config.namespace.clone(),
            DEFAULT_NICK_MAX,
            inbound.clone(),
        ));

        let reaper = Arc::clone(&manager);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(REAP_INTERVAL).await;
                reaper.reap_idle(USER_IDLE).await;
            }
        });

        info!(namespace = %config.namespace, "IRC event bus created (service + per-user sessions)");
        Self {
            cmd_tx,
            inbound,
            namespace: config.namespace,
            manager,
        }
    }
}

#[async_trait]
impl EventBus for IrcBus {
    async fn publisher(&self) -> Result<Box<dyn EventBusPublisher>> {
        Ok(Box::new(IrcPublisher::new(
            self.cmd_tx.clone(),
            Arc::clone(&self.manager),
            self.namespace.clone(),
        )))
    }

    async fn subscriber(&self, _topic_pattern: &str) -> Result<Box<dyn EventBusSubscriber>> {
        Ok(Box::new(IrcSubscriber::new(self.inbound.subscribe())))
    }

    async fn health_check(&self) -> Result<()> {
        if self.cmd_tx.is_closed() {
            return Err(realtime_core::RealtimeError::EventBusError(
                "IRC session task has stopped".to_string(),
            ));
        }
        Ok(())
    }

    async fn shutdown(&self) -> Result<()> {
        info!("IRC event bus shutting down");
        Ok(())
    }
}
