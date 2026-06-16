use crate::DataOperationKind;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IsolationLevel {
    ReadCommitted,
    RepeatableRead,
    Serializable,
    Snapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LatencyClass {
    Native,
    Adapter,
    Fdw,
    Remote,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PatternSearchCapability {
    Native,
    Indexed,
    Limited,
    Scan,
    Remote,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JoinCapability {
    Native,
    Limited,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CostCapabilities {
    pub latency_class: LatencyClass,
    pub pattern_search: PatternSearchCapability,
    pub joins: JoinCapability,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineCapabilities {
    pub read: bool,
    pub write: bool,
    pub upsert: bool,
    /// Whether the adapter implements the multi-row `Batch` operation. Distinct
    /// from `max_batch_size` (which only bounds the size *once* batch is
    /// supported). `#[serde(default)]` lets a partial descriptor payload omit
    /// this field and deserialise to `false` — the honest value for every
    /// adapter today — so adding the field is backward-compatible on the wire.
    #[serde(default)]
    pub batch: bool,
    /// Whether the adapter implements grouped `Aggregate` (count/sum/avg/min/max
    /// + group_by). `#[serde(default)]` for wire back-compat.
    #[serde(default)]
    pub aggregate: bool,
    /// Whether the adapter implements `describe_schema` (engine-agnostic schema
    /// introspection, M22). A *route* capability like `ddl` — gated at
    /// `POST /v1/schema`, never consulted by `supports_op`. `#[serde(default)]`
    /// lets a descriptor payload without the field deserialise to `false` (the
    /// honest value for redis/http), so adding it is wire backward-compatible.
    #[serde(default)]
    pub introspect: bool,
    /// Whether the adapter implements `apply_schema_ddl` (engine-agnostic,
    /// single-operation schema DDL: add/drop/retype column, create/drop
    /// table — M22 step 2). A *route* capability gated at
    /// `POST /v1/schema/ddl`, never consulted by `supports_op`.
    ///
    /// Deliberately DISTINCT from `ddl` (which gates the admin migration
    /// batch at `/v1/admin/migrate`): mongodb implements the
    /// `$jsonSchema`-validator DDL surface but NOT `apply_migration`, so
    /// flipping its `ddl` flag instead would break capability honesty.
    /// `#[serde(default)]` for wire back-compat (same precedent as
    /// `batch`/`aggregate`/`introspect`).
    #[serde(default)]
    pub schema_ddl: bool,
    pub stream: bool,
    pub ddl: bool,
    pub transactions: bool,
    pub savepoints: bool,
    pub isolation_levels: Vec<IsolationLevel>,
    pub two_phase_commit: bool,
    pub native_idempotency: bool,
    pub max_batch_size: u32,
    pub cost: CostCapabilities,
}

impl EngineCapabilities {
    /// Whether this engine serves the given operation kind, derived from the
    /// capability flags. This is the **single source of truth** the planner
    /// gates on, so a flag and the operation it governs can never disagree. Each
    /// adapter's `dispatch_op` must implement exactly the set for which this
    /// returns `true` — pinned by the capability-honesty test in
    /// `data-plane-pool`.
    #[must_use]
    pub fn supports_op(&self, kind: &DataOperationKind) -> bool {
        match kind {
            DataOperationKind::List | DataOperationKind::Get => self.read,
            DataOperationKind::Insert
            | DataOperationKind::Update
            | DataOperationKind::Delete => self.write,
            DataOperationKind::Upsert => self.upsert,
            DataOperationKind::Batch => self.batch,
            DataOperationKind::Aggregate => self.aggregate,
        }
    }

    #[must_use]
    pub fn postgresql() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: true,
            aggregate: true,
            introspect: true,
            schema_ddl: true,
            stream: true,
            ddl: true,
            transactions: true,
            savepoints: true,
            isolation_levels: vec![
                IsolationLevel::ReadCommitted,
                IsolationLevel::RepeatableRead,
                IsolationLevel::Serializable,
            ],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Native,
                joins: JoinCapability::Native,
            },
        }
    }

    /// CockroachDB — served by the Postgres adapter over pgwire (same CRUD /
    /// upsert / batch / aggregate / introspection surface), so the op flags
    /// match Postgres. It diverges honestly in two ways: it offers only
    /// SERIALIZABLE isolation (its sole transaction level), and it does not
    /// expose the LISTEN/NOTIFY streaming Postgres does (`stream: false`).
    #[must_use]
    pub fn cockroachdb() -> Self {
        Self {
            stream: false,
            isolation_levels: vec![IsolationLevel::Serializable],
            ..Self::postgresql()
        }
    }

    #[must_use]
    pub fn mongodb() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: true,
            aggregate: true,
            introspect: true,
            // The validator-based DDL surface (collMod / createCollection) IS
            // implemented — distinct from `ddl: false` below, which honestly
            // reports that `apply_migration` is NotImplemented on mongo.
            schema_ddl: true,
            stream: true,
            ddl: false,
            // mongo's `begin()` returns NotImplemented (session-threading
            // refactor pending), so advertising transactions would be a lie.
            transactions: false,
            savepoints: false,
            isolation_levels: vec![IsolationLevel::Snapshot],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Indexed,
                joins: JoinCapability::Limited,
            },
        }
    }

    #[must_use]
    pub fn mysql() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: true,
            aggregate: true,
            introspect: true,
            schema_ddl: true,
            stream: false,
            ddl: true,
            transactions: true,
            savepoints: true,
            isolation_levels: vec![
                IsolationLevel::ReadCommitted,
                IsolationLevel::RepeatableRead,
                IsolationLevel::Serializable,
            ],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Indexed,
                joins: JoinCapability::Native,
            },
        }
    }

    /// MariaDB — wire-compatible with MySQL and served by the same adapter,
    /// so the capability surface is identical. Kept as a distinct constructor
    /// (not an alias) so a future MariaDB-only divergence has a home and the
    /// descriptor reads honestly at `/v1/capabilities`.
    #[must_use]
    pub fn mariadb() -> Self {
        Self::mysql()
    }

    /// SQLite — embedded engine (rusqlite, file-per-mount). Relational surface:
    /// CRUD, upsert (INSERT…ON CONFLICT), ATOMIC batch (one tx per request),
    /// aggregate (GROUP BY), introspection (pragma), structured single-op
    /// schema DDL (`build_sqlite_ddl`: create/drop table, add/drop column;
    /// `alter_column_type` is honestly rejected — SQLite has no ALTER COLUMN).
    /// No LISTEN/NOTIFY streaming. `transactions:false` — the deadpool-sqlite
    /// `interact` model makes a connection-pinned, cross-request multi-statement
    /// TxHandle disproportionate; `begin()` honestly returns NotImplemented (a
    /// single batch is still atomic). Honest descriptor: conformance skips
    /// exactly what's false here.
    #[must_use]
    pub fn sqlite() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: true,
            aggregate: true,
            introspect: true,
            schema_ddl: true,
            stream: false,
            ddl: false,
            transactions: false,
            savepoints: false,
            isolation_levels: vec![],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Indexed,
                joins: JoinCapability::Native,
            },
        }
    }

    /// Microsoft SQL Server (TDS / tiberius). Relational surface: CRUD, upsert
    /// (MERGE), ATOMIC batch (BEGIN TRAN), aggregate, introspection
    /// (INFORMATION_SCHEMA). No streaming. Like SQLite, `transactions:false` —
    /// a cross-request pinned TxHandle is not exposed (a single batch is still
    /// atomic); `schema_ddl:false` (no apply_schema_ddl). Honest descriptor.
    #[must_use]
    pub fn mssql() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: true,
            aggregate: true,
            introspect: true,
            schema_ddl: false,
            stream: false,
            ddl: false,
            transactions: false,
            savepoints: false,
            isolation_levels: vec![],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Indexed,
                joins: JoinCapability::Native,
            },
        }
    }

    #[must_use]
    pub fn redis() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: true,
            aggregate: false,
            introspect: false,
            schema_ddl: false,
            stream: false,
            ddl: false,
            transactions: false,
            savepoints: false,
            isolation_levels: vec![],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 100,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Scan,
                joins: JoinCapability::None,
            },
        }
    }

    /// DynamoDB-compatible engine (8th adapter, OFF by default) — AWS DynamoDB /
    /// DynamoDB-Local / ScyllaDB Alternator, all reached by the same
    /// `aws-sdk-dynamodb` client with only an endpoint override. Sibling to
    /// `redis()` (KV/document, owner-prefixed keys, no joins, no aggregate) with
    /// one genuine addition the Redis adapter never had: native transactions.
    ///
    /// Honesty call-outs (every flag is a claim the capability-honesty gate and
    /// the m88 live gate must survive — see `wiki/dynamodb-htap-engine.md` §4):
    /// * `aggregate: false` — DynamoDB has NO server-side grouped aggregation;
    ///   `op=aggregate` is served OUTSIDE this engine by the OLAP export bridge
    ///   (Trino federation), so claiming it here would be a lie. This is the
    ///   single CRUD-family op excluded, exactly like Redis.
    /// * `transactions: true` — `TransactWriteItems` is an all-or-nothing write
    ///   across up to 100 items; the adapter's `begin()` returns a real
    ///   buffer-then-commit `TxHandle`.
    /// * `two_phase_commit: true` — justified by ATOMIC MULTI-ITEM all-or-nothing
    ///   (`TransactWriteItems`), NOT a wire-level XA/2PC handshake. (Same care the
    ///   postgres/mongo comments take so a reader doesn't assume distributed-XA.)
    /// * `native_idempotency: true` — the ONLY adapter that can honestly set this:
    ///   `ClientRequestToken` makes the service de-duplicate a re-sent transact,
    ///   so exactly-once is engine-guaranteed, not app-emulated.
    /// * `introspect`/`schema_ddl: true` — `DescribeTable`/`ListTables` give a
    ///   real (key-only) `SchemaDescriptor`; `CreateTable`/`DeleteTable` are a
    ///   genuine single-op DDL surface. Both are ROUTE capabilities (like `ddl`)
    ///   and never leak into `supports_op`. `ddl: false` — there is no
    ///   transactional multi-statement `apply_migration` (mirrors mongo).
    /// * `stream: false` for the MVP — DynamoDB Streams CDC is designed but
    ///   DEFERRED until the producer exists (capability-honesty forbids
    ///   advertising it early).
    #[must_use]
    pub fn dynamodb() -> Self {
        Self {
            read: true,          // GetItem / Query / Scan
            write: true,         // PutItem / UpdateItem / DeleteItem
            upsert: true,        // PutItem (no condition) = last-writer-wins
            batch: true,         // BatchWriteItem (NON-atomic, max 25)
            aggregate: false,    // no server-side GROUP BY/SUM — OLAP is the bridge
            introspect: false,   // describe_schema NOT implemented in the MVP (DescribeTable/ListTables→SchemaDescriptor deferred); advertising it would be a route-cap lie
            schema_ddl: false,   // apply_schema_ddl NOT implemented in the MVP (CreateTable/DeleteTable deferred); keep the descriptor honest vs the adapter
            stream: false,       // DynamoDB Streams CDC DESIGNED but DEFERRED (MVP)
            ddl: false,          // no apply_migration batch (mirrors mongo)
            transactions: true,  // TransactWriteItems (buffer-then-commit TxHandle)
            savepoints: false,   // no nested savepoint in a single transact call
            isolation_levels: vec![IsolationLevel::Serializable],
            two_phase_commit: true,   // all-or-nothing across items (NOT wire 2PC)
            native_idempotency: true, // ClientRequestToken de-dupes a transact
            max_batch_size: 25,       // BatchWriteItem hard limit (NOT the 100-item transact limit)
            cost: CostCapabilities {
                latency_class: LatencyClass::Native, // first-class driver, not an FDW
                pattern_search: PatternSearchCapability::Indexed, // Query indexed; Scan fallback
                joins: JoinCapability::None,         // KV/document — no joins (like redis/http)
            },
        }
    }

    #[must_use]
    pub fn http() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: false,
            aggregate: false,
            introspect: false,
            schema_ddl: false,
            stream: false,
            ddl: false,
            transactions: false,
            savepoints: false,
            isolation_levels: vec![],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 50,
            cost: CostCapabilities {
                latency_class: LatencyClass::Remote,
                pattern_search: PatternSearchCapability::Remote,
                joins: JoinCapability::None,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn introspect_flag_matches_each_engine_introspection_surface() {
        // M22: engines with a describe_schema implementation advertise it;
        // engines without one (redis KV, http passthrough) honestly do not.
        assert!(EngineCapabilities::postgresql().introspect);
        assert!(EngineCapabilities::mysql().introspect);
        assert!(EngineCapabilities::mongodb().introspect);
        assert!(!EngineCapabilities::redis().introspect);
        assert!(!EngineCapabilities::http().introspect);
    }

    #[test]
    fn capabilities_payload_without_introspect_still_deserializes() {
        // Wire back-compat (same precedent as `batch`/`aggregate`): a
        // descriptor serialized BEFORE the field existed must keep
        // deserializing, with `introspect` defaulting to false.
        let mut payload = serde_json::to_value(EngineCapabilities::postgresql())
            .expect("descriptor serializes");
        payload
            .as_object_mut()
            .expect("descriptor is a JSON object")
            .remove("introspect")
            .expect("introspect was present before removal");
        let parsed: EngineCapabilities =
            serde_json::from_value(payload).expect("old payload still deserializes");
        assert!(!parsed.introspect, "absent introspect defaults to false");
        // Everything else survives untouched.
        assert!(parsed.read && parsed.ddl && parsed.transactions);
    }

    #[test]
    fn introspect_never_leaks_into_supports_op() {
        // `introspect` is a route capability (like `ddl`), not an operation
        // kind: flipping it must not change any supports_op answer.
        let mut caps = EngineCapabilities::redis();
        let before: Vec<bool> = DataOperationKind::ALL
            .iter()
            .map(|k| caps.supports_op(k))
            .collect();
        caps.introspect = true;
        let after: Vec<bool> = DataOperationKind::ALL
            .iter()
            .map(|k| caps.supports_op(k))
            .collect();
        assert_eq!(before, after);
    }

    #[test]
    fn schema_ddl_flag_matches_each_engine_ddl_surface() {
        // M22 step 2: engines with an apply_schema_ddl implementation
        // advertise it; engines without one (redis KV, http passthrough)
        // honestly do not. Mongo advertises schema_ddl (the jsonSchema
        // validator surface) while still NOT advertising `ddl`
        // (apply_migration is NotImplemented there) — the two flags are
        // deliberately independent.
        assert!(EngineCapabilities::postgresql().schema_ddl);
        assert!(EngineCapabilities::mysql().schema_ddl);
        assert!(EngineCapabilities::mongodb().schema_ddl);
        assert!(!EngineCapabilities::redis().schema_ddl);
        assert!(!EngineCapabilities::http().schema_ddl);
        // The capability-honesty invariant the plan pins: mongodb's migrate
        // gate stays false even though its schema_ddl gate is true.
        assert!(!EngineCapabilities::mongodb().ddl);
    }

    #[test]
    fn capabilities_payload_without_schema_ddl_still_deserializes() {
        // Wire back-compat (same precedent as `batch`/`aggregate`/
        // `introspect`): a descriptor serialized BEFORE the field existed must
        // keep deserializing, with `schema_ddl` defaulting to false.
        let mut payload = serde_json::to_value(EngineCapabilities::postgresql())
            .expect("descriptor serializes");
        payload
            .as_object_mut()
            .expect("descriptor is a JSON object")
            .remove("schema_ddl")
            .expect("schema_ddl was present before removal");
        let parsed: EngineCapabilities =
            serde_json::from_value(payload).expect("old payload still deserializes");
        assert!(!parsed.schema_ddl, "absent schema_ddl defaults to false");
        // Everything else survives untouched.
        assert!(parsed.read && parsed.ddl && parsed.introspect && parsed.transactions);
    }

    #[test]
    fn dynamodb_descriptor_is_internally_consistent() {
        // The 8th adapter (OFF by default). supports_op() must agree with the
        // flags exactly — the same invariant the capability-honesty gate pins —
        // and the honest call-outs from the design must hold.
        let caps = EngineCapabilities::dynamodb();
        // CRUD + upsert + batch served; aggregate is the ONLY excluded op (like
        // redis), because DynamoDB has no server-side grouped aggregation.
        assert!(caps.supports_op(&DataOperationKind::Get));
        assert!(caps.supports_op(&DataOperationKind::List));
        assert!(caps.supports_op(&DataOperationKind::Insert));
        assert!(caps.supports_op(&DataOperationKind::Update));
        assert!(caps.supports_op(&DataOperationKind::Delete));
        assert!(caps.supports_op(&DataOperationKind::Upsert));
        assert!(caps.supports_op(&DataOperationKind::Batch));
        assert!(
            !caps.supports_op(&DataOperationKind::Aggregate),
            "DynamoDB has no server-side aggregate — OLAP is the export bridge"
        );
        // The headline capabilities the design justifies.
        assert!(caps.transactions, "TransactWriteItems backs begin()");
        assert!(caps.two_phase_commit, "all-or-nothing across items");
        assert!(
            caps.native_idempotency,
            "ClientRequestToken — the only adapter that can honestly set this"
        );
        // Route capabilities introspect/schema_ddl are honestly FALSE in the
        // MVP: the adapter overrides neither describe_schema nor
        // apply_schema_ddl, so advertising either would be a route-cap lie.
        assert!(!caps.introspect && !caps.schema_ddl);
        assert!(!caps.ddl, "no apply_migration batch (mirrors mongo)");
        assert!(!caps.stream, "Streams CDC deferred in the MVP");
        assert!(!caps.aggregate);
        assert_eq!(caps.max_batch_size, 25, "BatchWriteItem hard limit");
        assert_eq!(caps.isolation_levels, vec![IsolationLevel::Serializable]);
        // Route capabilities never leak into supports_op (same precedent as the
        // introspect/schema_ddl leak tests above).
        let mut probe = caps.clone();
        let before: Vec<bool> = DataOperationKind::ALL
            .iter()
            .map(|k| probe.supports_op(k))
            .collect();
        probe.introspect = !probe.introspect;
        probe.schema_ddl = !probe.schema_ddl;
        let after: Vec<bool> = DataOperationKind::ALL
            .iter()
            .map(|k| probe.supports_op(k))
            .collect();
        assert_eq!(before, after, "route caps must not change supports_op");
    }

    #[test]
    fn schema_ddl_never_leaks_into_supports_op() {
        // `schema_ddl` is a route capability: flipping it must not change any
        // supports_op answer.
        let mut caps = EngineCapabilities::redis();
        let before: Vec<bool> = DataOperationKind::ALL
            .iter()
            .map(|k| caps.supports_op(k))
            .collect();
        caps.schema_ddl = true;
        let after: Vec<bool> = DataOperationKind::ALL
            .iter()
            .map(|k| caps.supports_op(k))
            .collect();
        assert_eq!(before, after);
    }
}
