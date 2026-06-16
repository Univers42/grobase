pub mod capability;
pub mod error;
pub mod filter;
pub mod identity;
pub mod isolation;
pub mod mount;
pub mod operation;
pub mod plan;
pub mod planner;
pub mod ports;
pub mod schema;
pub mod schema_ddl;
pub mod transaction;

pub use capability::{CostCapabilities, EngineCapabilities, IsolationLevel};
pub use error::{DataPlaneError, DataPlaneResult};
pub use filter::{CmpOp, Filter, Folded};
pub use plan::{plan, OpShape, Plan, PlanDecision, WorkloadContext};
pub use planner::{
    apply_capability_overrides, required_capability, tier_gate, validate_operation,
};
pub use identity::{IdentitySource, RequestIdentity};
pub use isolation::{safe_schema, Isolation, ScopeDirective};
pub use mount::{CredentialRef, DatabaseMount, PoolPolicy};
pub use operation::{
    AggFunc, Aggregate, AggregateSpec, BatchItemOutcome, BatchItemStatus, BatchSummary,
    DataOperation, DataOperationKind, DataResult, ReturningMode, SearchSpec, VectorSpec,
};
pub use ports::{
    EngineAdapter, EngineHealth, EnginePool, MigrationRequest, MigrationResult, MigrationStatus,
    PoolRegistry, PoolStats, RawStatement, TxHandle,
};
pub use schema::{ColumnSchema, ForeignKeyRef, NormalizedType, SchemaDescriptor, TableSchema};
pub use schema_ddl::{
    validate_default_expr, DdlColumnDef, SchemaDdlOp, SchemaDdlRequest, SchemaDdlResult,
    SchemaDdlStatus,
};
pub use transaction::{TxBeginRequest, TxSession, TxState};
