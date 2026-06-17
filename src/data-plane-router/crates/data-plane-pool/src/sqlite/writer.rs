//! Single-writer GROUP COMMIT machinery.
//!
//! One OS thread owns one write connection per mount. Queued jobs execute in
//! groups of up to [`GROUP_MAX`] inside ONE transaction — a SAVEPOINT per job
//! keeps per-job atomicity (a failing job rolls back only itself) — so the
//! per-commit cost (and the WAL-checkpoint share) is amortized across the
//! group. Replies are sent only AFTER the group commits: an acked write is a
//! committed write.

use data_plane_core::{
    BatchItemOutcome, BatchItemStatus, BatchSummary, DataPlaneError, DataPlaneResult, DataResult,
};
use rusqlite::types::Value as SqlValue;
use rusqlite::Connection;

use super::error::classify_sqlite_ddl_error;
use super::exec::{exec_write, query_rows, run_plan};
use super::query::SqlPlan;

/// Upper bound on jobs coalesced into one transaction. Big enough to amortize
/// the commit under load, small enough to bound reply latency for the first
/// job in a group.
const GROUP_MAX: usize = 128;

pub(super) enum WriteJob {
    /// One built CRUD statement (insert/update/delete/upsert).
    Plan(SqlPlan, tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>),
    /// An atomic multi-statement batch (its own savepoint = all-or-nothing).
    Batch(
        Vec<(SqlPlan, String)>,
        tokio::sync::oneshot::Sender<DataPlaneResult<BatchSummary>>,
    ),
    /// Raw write/DDL SQL (`expect_rows=false` shape).
    Raw {
        sql: String,
        params: Vec<SqlValue>,
        reply: tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>,
    },
    /// A structured-DDL statement (classified errors).
    Ddl(String, tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>),
}

/// A processed job's deferred outcome: replies fire after COMMIT.
enum Deferred {
    Data(
        tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>,
        DataPlaneResult<DataResult>,
    ),
    Batch(
        tokio::sync::oneshot::Sender<DataPlaneResult<BatchSummary>>,
        DataPlaneResult<BatchSummary>,
    ),
}

impl Deferred {
    /// Send the buffered outcome; `commit_ok=false` downgrades a success to a
    /// backend error (the group's COMMIT failed → nothing persisted).
    fn send(self, commit_ok: bool) {
        fn gate<T>(commit_ok: bool, r: DataPlaneResult<T>) -> DataPlaneResult<T> {
            match (commit_ok, r) {
                (false, Ok(_)) => Err(DataPlaneError::Backend {
                    message: "sqlite group commit failed".into(),
                }),
                (_, r) => r,
            }
        }
        match self {
            Self::Data(tx, r) => {
                let _ = tx.send(gate(commit_ok, r));
            }
            Self::Batch(tx, r) => {
                let _ = tx.send(gate(commit_ok, r));
            }
        }
    }
}

fn open_writer_conn(path: &str) -> Result<Connection, rusqlite::Error> {
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "busy_timeout", 5000)?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    Ok(conn)
}

pub(super) fn writer_loop(path: &str, mut jobs: tokio::sync::mpsc::UnboundedReceiver<WriteJob>) {
    let conn = match open_writer_conn(path) {
        Ok(c) => c,
        Err(e) => {
            // Fail every job with the open error; senders see Backend.
            let msg = format!("sqlite writer connection failed: {e}");
            while let Some(job) = jobs.blocking_recv() {
                let err = || DataPlaneError::Backend { message: msg.clone() };
                match job {
                    WriteJob::Plan(_, tx) | WriteJob::Raw { reply: tx, .. } | WriteJob::Ddl(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                    WriteJob::Batch(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                }
            }
            return;
        }
    };

    // Exits when every sender is dropped (the pool was closed/evicted).
    while let Some(first) = jobs.blocking_recv() {
        let mut group = vec![first];
        while group.len() < GROUP_MAX {
            match jobs.try_recv() {
                Ok(job) => group.push(job),
                Err(_) => break,
            }
        }

        if let Err(e) = conn.execute_batch("BEGIN IMMEDIATE") {
            let msg = format!("sqlite begin failed: {e}");
            for job in group {
                let err = || DataPlaneError::Backend { message: msg.clone() };
                match job {
                    WriteJob::Plan(_, tx) | WriteJob::Raw { reply: tx, .. } | WriteJob::Ddl(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                    WriteJob::Batch(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                }
            }
            continue;
        }

        let mut deferred: Vec<Deferred> = Vec::with_capacity(group.len());
        for (i, job) in group.into_iter().enumerate() {
            deferred.push(process_in_savepoint(&conn, i, job));
        }
        let commit_ok = conn.execute_batch("COMMIT").is_ok();
        if !commit_ok {
            // Roll anything half-open back so the connection is reusable.
            let _ = conn.execute_batch("ROLLBACK");
        }
        for d in deferred {
            d.send(commit_ok);
        }
    }
}

/// Run one job inside its own savepoint: a failing job rolls back ONLY itself;
/// the surrounding group transaction (and its siblings) proceed.
fn process_in_savepoint(conn: &Connection, idx: usize, job: WriteJob) -> Deferred {
    let sp = format!("g{idx}");
    if let Err(e) = conn.execute_batch(&format!("SAVEPOINT {sp}")) {
        let err = DataPlaneError::Backend {
            message: format!("sqlite savepoint: {e}"),
        };
        return match job {
            WriteJob::Plan(_, tx) | WriteJob::Raw { reply: tx, .. } | WriteJob::Ddl(_, tx) => {
                Deferred::Data(tx, Err(err))
            }
            WriteJob::Batch(_, tx) => Deferred::Batch(tx, Err(err)),
        };
    }
    let (outcome, failed): (Deferred, bool) = match job {
        WriteJob::Plan(plan, tx) => {
            let r = run_plan(conn, &plan);
            let failed = r.is_err();
            (Deferred::Data(tx, r), failed)
        }
        WriteJob::Raw { sql, params, reply } => {
            let r = exec_write(conn, &sql, &params).map(|affected| DataResult::new(vec![], affected));
            let failed = r.is_err();
            (Deferred::Data(reply, r), failed)
        }
        WriteJob::Ddl(sql, tx) => {
            let r = conn
                .execute(&sql, [])
                .map(|_| DataResult::new(vec![], 0))
                .map_err(|e| classify_sqlite_ddl_error(&e));
            let failed = r.is_err();
            (Deferred::Data(tx, r), failed)
        }
        WriteJob::Batch(plans, tx) => {
            let r = run_batch_in_savepoint(conn, &plans);
            let failed = r.is_err();
            (Deferred::Batch(tx, r), failed)
        }
    };
    if failed {
        // The job's own writes (if any) are undone; siblings are untouched.
        let _ = conn.execute_batch(&format!("ROLLBACK TO {sp}"));
    }
    let _ = conn.execute_batch(&format!("RELEASE {sp}"));
    outcome
}

/// The atomic-batch contract inside the group: all items or none. The caller
/// (`process_in_savepoint`) rolls the enclosing savepoint back on Err, which
/// undoes every item executed before the poison one.
fn run_batch_in_savepoint(
    conn: &Connection,
    plans: &[(SqlPlan, String)],
) -> DataPlaneResult<BatchSummary> {
    let mut items: Vec<BatchItemOutcome> = Vec::with_capacity(plans.len());
    for (idx, (plan, _kind)) in plans.iter().enumerate() {
        let res = if plan.returns_rows {
            query_rows(conn, &plan.sql, &plan.params).map(|_| 0u64)
        } else {
            exec_write(conn, &plan.sql, &plan.params)
        };
        match res {
            Ok(affected) => items.push(BatchItemOutcome {
                index: idx as u32,
                status: BatchItemStatus::Ok,
                affected_rows: affected,
                error: None,
            }),
            Err(e) => {
                return Err(DataPlaneError::prefix_message(
                    &format!("batch item {idx}: "),
                    e,
                ))
            }
        }
    }
    Ok(BatchSummary {
        atomic: true,
        items,
    })
}
