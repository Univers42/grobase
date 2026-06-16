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
use mongodb::{bson::doc, Client};
use realtime_core::{DatabaseProducer, EventEnvelope, EventStream, RealtimeError, Result};
use tokio::sync::mpsc;
use tracing::{error, info, warn};

use super::parser::{parse_change_event, MongoEventStream};
use super::MongoProducer;
use crate::config::MongoConfig;

#[async_trait]
impl DatabaseProducer for MongoProducer {
    async fn start(&self) -> Result<Box<dyn EventStream>> {
        self.running.store(true, Ordering::SeqCst);
        let client = connect_mongo(&self.config.uri).await?;
        let db = client.database(&self.config.database);
        let (tx, rx) = mpsc::channel::<EventEnvelope>(4096);
        spawn_change_stream(db, tx, self.config.clone(), Arc::clone(&self.running));
        Ok(Box::new(MongoEventStream::new(rx)))
    }

    async fn stop(&self) -> Result<()> {
        self.running.store(false, Ordering::SeqCst);
        info!("MongoDB CDC producer stopped");
        Ok(())
    }

    async fn health_check(&self) -> Result<()> {
        let client = connect_mongo(&self.config.uri)
            .await
            .map_err(|e| RealtimeError::Internal(format!("Health check failed: {e}")))?;
        client
            .database(&self.config.database)
            .run_command(doc! { "ping": 1 })
            .await
            .map_err(|e| RealtimeError::Internal(format!("Health check ping failed: {e}")))?;
        Ok(())
    }

    fn name(&self) -> &'static str {
        "mongodb"
    }
}

async fn connect_mongo(uri: &str) -> Result<Client> {
    Client::with_uri_str(uri)
        .await
        .map_err(|e| RealtimeError::Internal(format!("MongoDB connect failed: {e}")))
}

fn spawn_change_stream(
    db: mongodb::Database,
    tx: mpsc::Sender<EventEnvelope>,
    config: MongoConfig,
    running: Arc<std::sync::atomic::AtomicBool>,
) {
    tokio::spawn(async move {
        let pipeline = build_pipeline(&config);
        let change_stream_result = db.watch().pipeline(pipeline).await;
        let mut stream = match change_stream_result {
            Ok(cs) => cs,
            Err(e) => {
                error!("Failed to open change stream: {e}");
                return;
            }
        };
        info!(database = %config.database, "MongoDB change stream started");
        process_events(&mut stream, &tx, &config, &running).await;
        info!("MongoDB change stream producer stopped");
    });
}

fn build_pipeline(config: &MongoConfig) -> Vec<mongodb::bson::Document> {
    if config.collections.is_empty() {
        return vec![];
    }
    let names: Vec<&str> = config.collections.iter().map(|c| c.name.as_str()).collect();
    vec![doc! { "$match": { "ns.coll": { "$in": names } } }]
}

#[allow(clippy::cognitive_complexity)]
async fn process_events(
    stream: &mut mongodb::change_stream::ChangeStream<
        mongodb::change_stream::event::ChangeStreamEvent<mongodb::bson::Document>,
    >,
    tx: &mpsc::Sender<EventEnvelope>,
    config: &MongoConfig,
    running: &Arc<std::sync::atomic::AtomicBool>,
) {
    while running.load(Ordering::SeqCst) {
        match stream.next().await {
            Some(Ok(change_event)) => {
                if let Ok(raw_doc) = mongodb::bson::to_document(&change_event) {
                    if let Some(event) =
                        parse_change_event(&raw_doc, &config.topic_prefix, &config.database)
                    {
                        if tx.send(event).await.is_err() {
                            warn!("Event channel closed, stopping MongoDB producer");
                            break;
                        }
                    }
                }
            }
            Some(Err(e)) => {
                error!("Change stream error: {e}");
                break;
            }
            None => {
                info!("Change stream ended");
                break;
            }
        }
    }
}
