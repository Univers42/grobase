/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lifecycle.rs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Lifecycle methods: `start()`, `stop()`, `health_check()`, `name()`.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use async_trait::async_trait;
use futures::StreamExt;
use realtime_core::{DatabaseProducer, EventEnvelope, EventStream, RealtimeError, Result};
use tokio::sync::mpsc;
use tokio_postgres::{AsyncMessage, NoTls};
use tracing::{debug, error, info, warn};

use super::parser::{parse_pg_notification, PostgresEventStream};
use super::PostgresProducer;

#[async_trait]
impl DatabaseProducer for PostgresProducer {
    async fn start(&self) -> Result<Box<dyn EventStream>> {
        self.running.store(true, Ordering::SeqCst);
        let (client, connection) = connect_pg(&self.config.connection_string).await?;
        let (tx, rx) = mpsc::channel::<EventEnvelope>(4096);
        spawn_listener(connection, tx, &self.config, &self.running);
        issue_listen(&client, &self.config.channel).await?;
        store_client(&self.client, client)?;
        Ok(Box::new(PostgresEventStream::new(rx)))
    }

    async fn stop(&self) -> Result<()> {
        self.running.store(false, Ordering::SeqCst);
        let mut guard = self
            .client
            .lock()
            .map_err(|e| RealtimeError::Internal(format!("Mutex poisoned: {e}")))?;
        *guard = None;
        drop(guard);
        info!("PostgreSQL CDC producer stopped");
        Ok(())
    }

    async fn health_check(&self) -> Result<()> {
        let (client, connection) = connect_pg(&self.config.connection_string)
            .await
            .map_err(|e| RealtimeError::Internal(format!("Health check failed: {e}")))?;
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                error!("Health check connection error: {}", e);
            }
        });
        client
            .simple_query("SELECT 1")
            .await
            .map_err(|e| RealtimeError::Internal(format!("Health check query failed: {e}")))?;
        Ok(())
    }

    fn name(&self) -> &'static str {
        "postgresql"
    }
}

async fn connect_pg(
    conn_str: &str,
) -> Result<(
    tokio_postgres::Client,
    tokio_postgres::Connection<tokio_postgres::Socket, tokio_postgres::tls::NoTlsStream>,
)> {
    tokio_postgres::connect(conn_str, NoTls)
        .await
        .map_err(|e| RealtimeError::Internal(format!("PostgreSQL connect failed: {e}")))
}

fn spawn_listener(
    connection: tokio_postgres::Connection<
        tokio_postgres::Socket,
        tokio_postgres::tls::NoTlsStream,
    >,
    tx: mpsc::Sender<EventEnvelope>,
    config: &crate::config::PostgresConfig,
    running: &Arc<std::sync::atomic::AtomicBool>,
) {
    let topic_prefix = config.topic_prefix.clone();
    let running = Arc::clone(running);
    let mut connection = connection;
    tokio::spawn(async move {
        let mut stream = futures::stream::poll_fn(move |cx| connection.poll_message(cx));
        process_notifications(&mut stream, &tx, &topic_prefix, &running).await;
    });
    info!(channel = %config.channel, "PostgreSQL CDC producer started");
}

#[allow(clippy::cognitive_complexity)]
async fn process_notifications(
    stream: &mut (impl futures::Stream<Item = std::result::Result<AsyncMessage, tokio_postgres::Error>>
              + Unpin),
    tx: &mpsc::Sender<EventEnvelope>,
    topic_prefix: &str,
    running: &Arc<std::sync::atomic::AtomicBool>,
) {
    loop {
        if !running.load(Ordering::SeqCst) {
            break;
        }
        match stream.next().await {
            Some(Ok(AsyncMessage::Notification(n))) => {
                debug!(channel = %n.channel(), "Received PostgreSQL notification");
                if let Some(event) = parse_pg_notification(n.payload(), topic_prefix) {
                    if tx.send(event).await.is_err() {
                        warn!("Event channel closed, stopping PostgreSQL producer");
                        break;
                    }
                }
            }
            Some(Ok(AsyncMessage::Notice(notice))) => {
                debug!("PostgreSQL notice: {}", notice.message());
            }
            Some(Ok(_)) => {}
            Some(Err(e)) => {
                error!("PostgreSQL connection error: {}", e);
                break;
            }
            None => {
                info!("PostgreSQL connection closed");
                break;
            }
        }
    }
}

async fn issue_listen(client: &tokio_postgres::Client, channel: &str) -> Result<()> {
    let query = format!("LISTEN {channel}");
    client
        .batch_execute(&query)
        .await
        .map_err(|e| RealtimeError::Internal(format!("LISTEN failed: {e}")))
}

fn store_client(
    mutex: &std::sync::Mutex<Option<tokio_postgres::Client>>,
    client: tokio_postgres::Client,
) -> Result<()> {
    let mut guard = mutex
        .lock()
        .map_err(|e| RealtimeError::Internal(format!("Mutex poisoned: {e}")))?;
    *guard = Some(client);
    drop(guard);
    Ok(())
}
