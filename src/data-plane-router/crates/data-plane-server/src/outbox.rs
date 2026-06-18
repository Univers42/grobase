//! Phase 7d — outbox emission for the direct `/data/v1` front door.
//!
//! The outbox-relay → Redis Streams → realtime / webhooks / projections pipeline
//! reads `public.outbox_events` and never sees the producer. When a write goes
//! through the TS query-router, IT emits the event; when a write goes through
//! the Rust bypass, the query-router is no longer in the path, so the data plane
//! must emit the SAME row shape itself — or row-change fan-out silently stops
//! after cutover. This module does exactly that, matching the query-router's
//! `OutboxService.emitForQuery` column set + payload so downstream consumers are
//! oblivious to which plane produced the event.
//!
//! No-op only when `DATA_PLANE_OUTBOX_DSN` is unset. The default compose sets
//! it (to the system Postgres) and `/data/v1` is on by default, so this emitter
//! is LIVE on the standard stack — the Rust plane stamps the same authoritative
//! top-level `tenant_id` (the verified slug, identical to the TS query-router)
//! that the function-trigger + webhook dispatchers tenant-scope delivery on.
//!
//! ## D-write-tail (background emission)
//!
//! The original design `.await`-ed the outbox INSERT inline on the request path
//! — a *second* synchronous DB round-trip after the user's write already
//! committed, measured at insert p99 583 ms vs read 3.4 ms. The event is
//! best-effort and already decoupled from the write's success, so it has no
//! business on the latency-critical path. [`BackgroundOutbox`] moves it onto a
//! bounded queue drained by a spawned worker that **batches** ready events into
//! one multi-row INSERT. The handler does a non-blocking `enqueue` (drop+count
//! on a full queue, mirroring the realtime drop-counter posture) and returns
//! immediately — the insert tail collapses toward the primary-write latency.

use std::sync::Arc;

use deadpool_postgres::{Config as PgConfig, Pool, Runtime};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_postgres::NoTls;

use data_plane_core::{DataOperationKind, DataResult, RequestIdentity};

use crate::metrics::Metrics;

/// Default depth of the background outbox queue (events buffered before
/// back-pressure sheds). Override with `DATA_PLANE_OUTBOX_QUEUE`.
const DEFAULT_QUEUE_CAP: usize = 4096;
/// Max events coalesced into a single multi-row INSERT by the worker.
const BATCH_MAX: usize = 64;

/// A fully-materialized outbox row, built off the request path (no DB) so it can
/// be handed to the background worker. Mirrors the query-router column set.
#[derive(Clone)]
pub struct OutboxRow {
    resource: String,
    aggregate_id: String,
    event_type: String,
    payload: Value,
    op_str: String,
    idempotency_key: Option<String>,
}

impl OutboxRow {
    /// Build the row for a successful MUTATION, mirroring the query-router's
    /// `emitForQuery`. Pure (no I/O) — safe to call on the hot path; the actual
    /// INSERT is deferred to the worker. Returns `None` for the outbox table
    /// itself (would loop the relay).
    #[must_use]
    pub fn build(
        engine: &str,
        identity: &RequestIdentity,
        op: DataOperationKind,
        resource: &str,
        data: Option<&Value>,
        filter: Option<&Value>,
        result: &DataResult,
        idempotency_key: Option<&str>,
    ) -> Option<Self> {
        if resource == "outbox_events" {
            return None;
        }
        let op_str = op_str(op);
        let aggregate_id = aggregate_id(result, data, filter);
        let event_type = format!("{resource}.{op_str}");
        // Match the query-router payload: a bounded row sample + counts so a
        // consumer can act without re-reading the row.
        let sample: Vec<Value> = result.rows.iter().take(10).cloned().collect();
        let payload = json!({
            // Top-level AUTHORITATIVE tenant (slug) from the verified request
            // identity — the same value `apply_rls_context` scopes the write to,
            // never a user-writable row column. The outbox consumers
            // (function-trigger + webhook dispatchers) tenant-scope delivery on
            // this field, so it must be server-derived (cross-tenant-safe).
            "tenant_id": identity.tenant_id,
            "engine": engine,
            "resource": resource,
            "op": op_str,
            "data": data.cloned().unwrap_or(Value::Null),
            "filter": filter.cloned().unwrap_or(Value::Null),
            "rowCount": result.affected_rows,
            "rows": sample,
            // Provenance for parity diffing (additive, in-payload — no schema
            // change to the shared table).
            "emitted_by": "rust-data-plane",
        });
        // actor_id / request_id are uuid columns; the bypass principal is
        // `api-key:<uuid>` (not a bare uuid), which the query-router also nulls —
        // so both planes write NULL here (parity).
        Some(Self {
            resource: resource.to_string(),
            aggregate_id,
            event_type,
            payload,
            op_str: op_str.to_string(),
            idempotency_key: idempotency_key.map(str::to_string),
        })
    }
}

/// Writes row-change events to `public.outbox_events`. Cloneable-cheap (the pool
/// is an Arc inside).
pub struct OutboxEmitter {
    pool: Pool,
}

impl OutboxEmitter {
    /// Build from `DATA_PLANE_OUTBOX_DSN`. Returns `None` (→ no-op emission) when
    /// the DSN is unset, so the bypass works without the outbox until it's wired.
    #[must_use]
    pub fn from_env() -> Option<Self> {
        let dsn = std::env::var("DATA_PLANE_OUTBOX_DSN")
            .ok()
            .filter(|s| !s.trim().is_empty())?;
        let mut cfg = PgConfig::new();
        cfg.url = Some(dsn);
        let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls).ok()?;
        Some(Self { pool })
    }

    /// Promote this emitter to a background worker (D-write-tail). Consumes the
    /// emitter, spawns the drain loop, and returns the handle the request path
    /// enqueues onto. Queue depth comes from `DATA_PLANE_OUTBOX_QUEUE`.
    #[must_use]
    pub fn into_background(self, metrics: Arc<Metrics>) -> BackgroundOutbox {
        let cap = std::env::var("DATA_PLANE_OUTBOX_QUEUE")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .unwrap_or(DEFAULT_QUEUE_CAP);
        let (tx, rx) = mpsc::channel::<OutboxRow>(cap);
        let worker_metrics = metrics.clone();
        tokio::spawn(async move { self.run_worker(rx, worker_metrics).await });
        BackgroundOutbox { tx, metrics }
    }

    /// Drain loop: block for one row, opportunistically coalesce up to
    /// `BATCH_MAX` more that are already queued, write them in one INSERT.
    async fn run_worker(self, mut rx: mpsc::Receiver<OutboxRow>, metrics: Arc<Metrics>) {
        let mut batch: Vec<OutboxRow> = Vec::with_capacity(BATCH_MAX);
        while let Some(first) = rx.recv().await {
            batch.push(first);
            while batch.len() < BATCH_MAX {
                match rx.try_recv() {
                    Ok(row) => batch.push(row),
                    Err(_) => break,
                }
            }
            match self.write_rows(&batch).await {
                Ok(n) => metrics.record_outbox_written(n as u64),
                Err(e) => {
                    // The writes these events describe already committed — log
                    // and count, never retry-storm the (already-served) caller.
                    metrics.record_outbox_failed();
                    tracing::warn!(rows = batch.len(), "background outbox INSERT failed: {e}");
                }
            }
            batch.clear();
        }
    }

    /// One multi-row INSERT for a batch of events. A single failed checkout/
    /// insert fails the whole batch (best-effort — see `run_worker`).
    async fn write_rows(&self, rows: &[OutboxRow]) -> Result<usize, String> {
        if rows.is_empty() {
            return Ok(0);
        }
        let client = self
            .pool
            .get()
            .await
            .map_err(|e| format!("outbox pool checkout: {e}"))?;
        // Build a VALUES list with positional params: 6 columns per row.
        let mut sql = String::from(
            "INSERT INTO public.outbox_events \
               (aggregate, aggregate_id, event_type, payload, op, idempotency_key) VALUES ",
        );
        let mut params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> =
            Vec::with_capacity(rows.len() * 6);
        for (i, r) in rows.iter().enumerate() {
            if i > 0 {
                sql.push(',');
            }
            let b = i * 6;
            // `payload` binds as serde_json::Value so tokio-postgres serializes
            // it natively as JSONB (the `with-serde_json-1` feature).
            sql.push_str(&format!(
                "(${},${},${},${},${},${})",
                b + 1,
                b + 2,
                b + 3,
                b + 4,
                b + 5,
                b + 6
            ));
            params.push(&r.resource);
            params.push(&r.aggregate_id);
            params.push(&r.event_type);
            params.push(&r.payload);
            params.push(&r.op_str);
            params.push(&r.idempotency_key);
        }
        client
            .execute(sql.as_str(), &params)
            .await
            .map_err(|e| format!("outbox insert: {e}"))?;
        Ok(rows.len())
    }

    /// Emit one row-change event synchronously, mirroring the query-router's
    /// `emitForQuery`. Retained for the internal/non-bypass path and tests; the
    /// bypass write path now uses [`BackgroundOutbox::enqueue`] instead.
    pub async fn emit_mutation(
        &self,
        engine: &str,
        identity: &RequestIdentity,
        op: DataOperationKind,
        resource: &str,
        data: Option<&Value>,
        filter: Option<&Value>,
        result: &DataResult,
        idempotency_key: Option<&str>,
    ) -> Result<(), String> {
        let Some(row) = OutboxRow::build(
            engine,
            identity,
            op,
            resource,
            data,
            filter,
            result,
            idempotency_key,
        ) else {
            return Ok(());
        };
        self.write_rows(&[row]).await.map(|_| ())
    }
}

/// The request-path handle to background outbox emission (D-write-tail). Cheap
/// to clone (channel sender + Arc metrics inside).
#[derive(Clone)]
pub struct BackgroundOutbox {
    tx: mpsc::Sender<OutboxRow>,
    metrics: Arc<Metrics>,
}

impl BackgroundOutbox {
    /// Non-blocking enqueue. Builds the row off the DB path, then `try_send`s it
    /// to the worker. A full queue means the worker is behind: shed the event
    /// (count it as `dropped`) rather than stall the request — the write already
    /// committed, so this only delays a best-effort notification.
    #[allow(clippy::too_many_arguments)]
    pub fn enqueue(
        &self,
        engine: &str,
        identity: &RequestIdentity,
        op: DataOperationKind,
        resource: &str,
        data: Option<&Value>,
        filter: Option<&Value>,
        result: &DataResult,
        idempotency_key: Option<&str>,
    ) {
        let Some(row) = OutboxRow::build(
            engine,
            identity,
            op,
            resource,
            data,
            filter,
            result,
            idempotency_key,
        ) else {
            return;
        };
        match self.tx.try_send(row) {
            Ok(()) => self.metrics.record_outbox_enqueued(),
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.metrics.record_outbox_dropped();
                tracing::warn!(
                    resource,
                    "outbox queue full — event dropped (worker behind)"
                );
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                self.metrics.record_outbox_dropped();
            }
        }
    }
}

fn op_str(op: DataOperationKind) -> &'static str {
    match op {
        DataOperationKind::Insert => "insert",
        DataOperationKind::Update => "update",
        DataOperationKind::Delete => "delete",
        DataOperationKind::Upsert => "upsert",
        DataOperationKind::Batch => "batch",
        DataOperationKind::List => "list",
        DataOperationKind::Get => "get",
        DataOperationKind::Aggregate => "aggregate",
    }
}

/// The aggregate id, matching the query-router's precedence: the returned row's
/// `id`, else the write's `data.id`, else the `filter.id`, else "unknown".
fn aggregate_id(result: &DataResult, data: Option<&Value>, filter: Option<&Value>) -> String {
    let from_row = result
        .rows
        .first()
        .and_then(|r| r.get("id"))
        .and_then(value_to_id);
    let from_data = data.and_then(|d| d.get("id")).and_then(value_to_id);
    let from_filter = filter.and_then(|f| f.get("id")).and_then(value_to_id);
    from_row
        .or(from_data)
        .or(from_filter)
        .unwrap_or_else(|| "unknown".to_string())
}

fn value_to_id(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ident() -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t1".into(),
            project_id: None,
            app_id: None,
            user_id: Some("api-key:abc".into()),
            roles: vec![],
            scopes: vec![],
            source: data_plane_core::IdentitySource::Test,
        }
    }

    fn empty_result() -> DataResult {
        DataResult {
            rows: vec![],
            affected_rows: 0,
            next_cursor: None,
            batch: None,
        }
    }

    #[test]
    fn build_skips_outbox_table_to_avoid_loop() {
        let result = empty_result();
        assert!(OutboxRow::build(
            "postgresql",
            &ident(),
            DataOperationKind::Insert,
            "outbox_events",
            None,
            None,
            &result,
            None,
        )
        .is_none());
    }

    #[test]
    fn build_materializes_event_type_and_aggregate() {
        let mut result = empty_result();
        result.rows.push(json!({"id": "row-7", "name": "x"}));
        result.affected_rows = 1;
        let row = OutboxRow::build(
            "postgresql",
            &ident(),
            DataOperationKind::Update,
            "widgets",
            Some(&json!({"name": "x"})),
            Some(&json!({"id": "row-7"})),
            &result,
            Some("idem-1"),
        )
        .expect("row built");
        assert_eq!(row.event_type, "widgets.update");
        assert_eq!(row.aggregate_id, "row-7");
        assert_eq!(row.op_str, "update");
        assert_eq!(row.idempotency_key.as_deref(), Some("idem-1"));
        assert_eq!(row.payload["emitted_by"], "rust-data-plane");
        assert_eq!(row.payload["rowCount"], 1);
        // The authoritative tenant (slug) is stamped top-level so the outbox
        // consumers (function-trigger + webhook dispatchers) can tenant-scope
        // delivery — sourced from the verified identity, not a row column.
        assert_eq!(row.payload["tenant_id"], "t1");
    }

    #[test]
    fn aggregate_id_precedence_row_then_data_then_filter() {
        let empty = empty_result();
        // falls through to data.id
        assert_eq!(aggregate_id(&empty, Some(&json!({"id": 42})), None), "42");
        // then filter.id
        assert_eq!(aggregate_id(&empty, None, Some(&json!({"id": "f"}))), "f");
        // nothing → "unknown"
        assert_eq!(aggregate_id(&empty, None, None), "unknown");
    }
}
