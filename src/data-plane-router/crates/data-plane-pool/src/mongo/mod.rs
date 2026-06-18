//! MongoDB engine adapter — R3.
//!
//! Mirrors the design of [`crate::postgres`] but for the official `mongodb`
//! crate. The Rust driver already owns a connection pool per [`mongodb::Client`]
//! — we cache one Client per [`DatabaseMount::pool_key`] so the hot path never
//! pays the connect cost the legacy `MongodbEngine` TypeScript adapter does
//! on every request (`new MongoClient(uri).connect()` per call).
//!
//! Tenant isolation:
//!   * Every insert is decorated with `owner_id` and `tenant_id` from the
//!     verified [`RequestIdentity`] before reaching the wire — the document the
//!     client sent cannot override these fields.
//!   * Every read filter is intersected with the same fields, so a forged
//!     resource name still cannot leak cross-tenant rows.
//!
//! Pattern stack:
//!   * Adapter (GoF)       — implements [`EngineAdapter`].
//!   * Object Pool         — `mongodb::Client` is already a connection pool.
//!   * Strategy            — operation kind switches the executor branch.
//!   * Template Method     — `build_tenant_filter`/`build_owned_doc` shared
//!     across all read/write code paths.
//!
//! Split into concern modules (facade pattern, mirrors `routes/`): the adapter +
//! pool wiring (`adapter`/`pool`), the CRUD/filter builders (`query`), the
//! JSON↔BSON conversion (`convert`), the `$jsonSchema` DDL transforms (`schema`),
//! and the error classifiers (`error`). Cross-module symbols stay `pub(super)`;
//! the crate-facing surface is only the facade re-exported below.

mod adapter;
mod convert;
mod error;
mod filter;
mod pool;
mod query;
mod schema;

// ── crate-facing facade ──────────────────────────────────────────────────────
// `lib.rs` re-exports `MongoEngineAdapter`; `capability_honesty.rs` reads
// `crate::mongo::SUPPORTED_OPS`. Nothing wider than what was already
// `pub`/`pub(crate)` before the split is re-exported.
pub use adapter::MongoEngineAdapter;

use data_plane_core::DataOperationKind;

/// The operation kinds the Mongo adapter dispatches — the single source of
/// truth shared by `execute`'s gate, the capability descriptor, and the
/// honesty test.
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
