//! SQLite engine adapter (R-sqlite, Phase 3b).
//!
//! Embedded, file-per-mount engine on `rusqlite` (sync) driven through
//! `deadpool-sqlite`'s `interact()`, which runs each closure on a blocking
//! thread so the async runtime is never stalled. WAL is enabled at pool open
//! (1 writer + N concurrent readers) and `busy_timeout` smooths writer
//! contention. The DSN is a file path (`sqlite:///var/lib/mini-baas/<ref>.db`),
//! so a `db_per_tenant` mount is a distinct file; `shared_rls` mounts owner-scope
//! every read/write via an `owner_id` predicate exactly like the MySQL adapter
//! (SQLite has no RLS), and writes are owner-stamped so a forged body cannot
//! cross tenants.
//!
//! Honest descriptor (`EngineCapabilities::sqlite`): CRUD + upsert + ATOMIC
//! batch + aggregate + introspection. `transactions:false` — a connection-pinned
//! cross-request TxHandle is disproportionate under the `interact` model, so
//! `begin()` returns NotImplemented; a single batch is still atomic (one tx
//! inside one closure).
//!
//! Split into concern modules (facade pattern, mirrors `routes/`): the adapter +
//! pool wiring (`adapter`/`pool`), the pure plan/SQL builders (`query`), the
//! value conversion (`convert`), the blocking executors (`exec`), the
//! single-writer GROUP-COMMIT machinery (`writer`), the structured-DDL builders
//! (`schema`), and the error classifiers (`error`). Cross-module symbols stay
//! `pub(super)`/`pub(crate)`; the crate-facing surface is only the facade
//! re-exported below.

mod adapter;
mod columns;
mod convert;
mod error;
mod exec;
mod pool;
mod query;
mod schema;
mod writer;

// ── crate-facing facade ──────────────────────────────────────────────────────
// `lib.rs` re-exports `SqliteEngineAdapter`; `capability_honesty.rs` reads
// `crate::sqlite::SUPPORTED_OPS`. `sqlite_sql_type`/`build_sqlite_ddl` keep their
// pre-split `pub(crate)` visibility on the fns themselves (in `schema`); they are
// reached inside the module via `super::schema::…`, so no crate-level re-export
// is needed. Nothing wider than before is exposed.
pub use adapter::SqliteEngineAdapter;

use data_plane_core::DataOperationKind;

/// Server-controlled columns a client may never set/override.
pub(super) const RESERVED_COLUMNS: &[&str] = &["owner_id", "tenant_id"];

/// The op kinds this adapter dispatches — single source of truth for the
/// descriptor (via `capability_honesty`) and the per-request gate.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
    DataOperationKind::Aggregate,
    DataOperationKind::Batch,
];
