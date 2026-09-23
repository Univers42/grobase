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

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use futures::StreamExt;
use realtime_core::{DatabaseProducer, EventEnvelope, EventStream, RealtimeError, Result};
use tokio::sync::mpsc;
use tokio::time::{sleep, Duration};
use tokio_postgres::{AsyncMessage, NoTls};
use tracing::{debug, error, info, warn};

use super::parser::{parse_pg_notification, PostgresEventStream};
use super::PostgresProducer;

/// A driven connection, as a stream of protocol messages. Boxed so `attach` has
/// ONE nameable return type shared by the first attach and every re-attach.
type PgStream = Box<
    dyn futures::Stream<Item = std::result::Result<AsyncMessage, tokio_postgres::Error>>
        + Send
        + Unpin,
>;

/// Re-attach delay: doubles on each consecutive failure, capped.
/// No jitter on purpose — there is exactly one listener per database here, so
/// there is no herd to spread out, and a fixed floor makes the logs readable.
const RECONNECT_MIN: Duration = Duration::from_millis(250);
const RECONNECT_MAX: Duration = Duration::from_secs(30);

#[async_trait]
impl DatabaseProducer for PostgresProducer {
    async fn start(&self) -> Result<Box<dyn EventStream>> {
        self.running.store(true, Ordering::SeqCst);
        let (tx, rx) = mpsc::channel::<EventEnvelope>(4096);
        // The FIRST attach is synchronous so a bad DSN or an unusable channel
        // still fails start() loudly, instead of disappearing into a retry loop
        // that logs forever while the server reports itself healthy.
        let connection = attach(&self.config, &self.client).await?;
        self.connected.store(true, Ordering::SeqCst);
        let supervisor = Supervisor {
            tx,
            config: self.config.clone(),
            running: Arc::clone(&self.running),
            connected: Arc::clone(&self.connected),
            client: Arc::clone(&self.client),
        };
        tokio::spawn(supervisor.run(connection));
        info!(channel = %self.config.channel, "PostgreSQL CDC producer started");
        Ok(Box::new(PostgresEventStream::new(rx)))
    }

    async fn stop(&self) -> Result<()> {
        self.running.store(false, Ordering::SeqCst);
        self.connected.store(false, Ordering::SeqCst);
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

    fn attached(&self) -> Option<bool> {
        Some(self.is_connected())
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

/// Connect, issue the LISTEN, publish the client, and hand back the live stream.
///
/// The LISTEN is driven CONCURRENTLY with the connection, and that is not a
/// style choice: a `tokio_postgres::Client` makes no progress unless something
/// is polling its `Connection`, so awaiting `issue_listen` on its own deadlocks
/// outright — the server sits there with one idle backend and `start()` never
/// returns. The original code avoided it by spawning the driver before issuing
/// the LISTEN; that ordering is invisible and easy to lose, so it is written
/// down here instead.
async fn attach(
    config: &crate::config::PostgresConfig,
    client_slot: &Mutex<Option<tokio_postgres::Client>>,
) -> Result<PgStream> {
    let (client, mut connection) = connect_pg(&config.connection_string).await?;
    let mut stream: PgStream = Box::new(futures::stream::poll_fn(move |cx| {
        connection.poll_message(cx)
    }));
    listen_while_driving(&client, &config.channel, &mut stream).await?;
    store_client(client_slot, client)?;
    Ok(stream)
}

/// Await the LISTEN while polling the connection it has to travel over.
///
/// Anything the stream yields before the LISTEN completes is pre-subscription
/// protocol traffic and is discarded: there is nothing to deliver yet.
async fn listen_while_driving(
    client: &tokio_postgres::Client,
    channel: &str,
    stream: &mut PgStream,
) -> Result<()> {
    let listen = issue_listen(client, channel);
    tokio::pin!(listen);
    loop {
        tokio::select! {
            result = &mut listen => return result,
            _ = stream.next() => {}
        }
    }
}

/// Owns the LISTEN for the producer's whole life, across reconnects.
struct Supervisor {
    tx: mpsc::Sender<EventEnvelope>,
    config: crate::config::PostgresConfig,
    running: Arc<AtomicBool>,
    connected: Arc<AtomicBool>,
    client: Arc<Mutex<Option<tokio_postgres::Client>>>,
}

impl Supervisor {
    /// Drive the LISTEN, re-attaching for as long as the producer is running.
    ///
    /// Recreating Postgres closes the connection. Before this loop existed the
    /// listener task simply ended: the sender dropped, the server's consumer
    /// loop finished with NO log line, and the process carried on serving
    /// `WebSockets`. Subscribers connected, every container reported healthy, and
    /// no row change was ever delivered again until someone restarted realtime
    /// by hand — the platform's worst failure mode, healthy-but-wrong.
    async fn run(self, first: PgStream) {
        let mut stream = Some(first);
        let mut backoff = RECONNECT_MIN;
        while self.running.load(Ordering::SeqCst) {
            if let Some(mut s) = stream.take() {
                self.drive(&mut s).await;
            }
            if !self.running.load(Ordering::SeqCst) {
                break;
            }
            self.connected.store(false, Ordering::SeqCst);
            sleep(backoff).await;
            match attach(&self.config, &self.client).await {
                Ok(s) => {
                    self.connected.store(true, Ordering::SeqCst);
                    info!(channel = %self.config.channel, "PostgreSQL LISTEN re-attached");
                    stream = Some(s);
                    backoff = RECONNECT_MIN;
                }
                Err(e) => {
                    error!(error = %e, retry_in = ?backoff, "PostgreSQL re-attach failed");
                    backoff = (backoff * 2).min(RECONNECT_MAX);
                }
            }
        }
        self.connected.store(false, Ordering::SeqCst);
        info!("PostgreSQL CDC supervisor stopped");
    }

    /// Consume notifications until the connection ends or `stop()` is called.
    async fn drive(&self, stream: &mut PgStream) {
        process_notifications(stream, &self.tx, &self.config.topic_prefix, &self.running).await;
        warn!("PostgreSQL LISTEN dropped");
    }
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
