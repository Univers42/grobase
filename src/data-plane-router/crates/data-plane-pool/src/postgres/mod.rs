//! PostgreSQL engine adapter, split per concern.
//!
//! `lib.rs` resolves `mod postgres;` to this file and re-exports
//! `postgres::{PgDialect, PostgresEngineAdapter}` — unchanged crate-facing
//! surface. Each submodule owns one concern; everything shared across them is
//! `pub(super)` (visible only inside this module tree), so nothing newly leaks
//! to the crate. The split is byte-for-byte the pre-split code: same SQL, same
//! dispatch, same error classification, same RLS context.
//!
//! - [`conn`] — TLS posture + connection-pooler DSN repoint (pure helpers).
//! - [`adapter`] — `PgDialect`, the `EngineAdapter` impl (`open_pool`), and the
//!   `PostgresPool` struct with its tenant cross-check.
//! - [`pool`] — the `EnginePool` impl (execute/begin/close/raw + the schema
//!   methods, which delegate their bodies to [`schema`]).
//! - [`schema`] — introspection + DDL-apply + migration (the heavy method bodies).
//! - [`ddl`] — pure schema-DDL SQL builders + the type normalizer.
//! - [`tx`] — the pinned `PgTxHandle`, RLS/search-path application, op dispatch.
//! - [`query`] — read ops (list/get/aggregate).
//! - [`search`] — full-text + pgvector search-clause builders (pure).
//! - [`convert`] — JSON↔Postgres value binding + error classification.
//! - [`filter`] — the `Pred` filter compiler + ORDER BY builder.
//! - [`crud`] — mutating ops (insert/update/delete/upsert), effectful runners.
//! - [`crud_build`] — the pure mutating-op SQL builders (owner-scoped, tested).

mod adapter;
mod conn;
mod convert;
mod crud;
mod crud_build;
mod ddl;
mod filter;
mod pool;
mod query;
mod schema;
mod search;
mod tx;

// ── crate-facing facade ──────────────────────────────────────────────────────
// External callers reach these as `crate::postgres::X` exactly as before the
// split (lib.rs: `pub use postgres::{PgDialect, PostgresEngineAdapter};`).
// Nothing wider than what was already `pub` is re-exported.
pub use adapter::{PgDialect, PostgresEngineAdapter};
// `SUPPORTED_OPS` lives in `tx` (beside the dispatch match it guards); the
// capability-honesty battery reads it as `crate::postgres::SUPPORTED_OPS`.
#[cfg(test)]
pub(crate) use tx::SUPPORTED_OPS;

/// A JSON value boxed as a Postgres parameter whose wire encoding adapts to the
/// target column type (see [`convert::JsonParam`]). The single param type every
/// builder pushes — shared module-wide so the `$n` placeholder bookkeeping has
/// one source of truth.
pub(super) type BoxedParam = Box<dyn tokio_postgres::types::ToSql + Sync + Send>;
