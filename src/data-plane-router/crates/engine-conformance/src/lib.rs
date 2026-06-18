//! Reusable engine-conformance battery.
//!
//! [`run_suite`] drives an [`EngineAdapter`] through its public [`EnginePool`]
//! surface against a real engine (no HTTP) and asserts the adapter serves
//! EXACTLY what its [`EngineCapabilities`] descriptor advertises. The descriptor
//! IS the profile: the suite tests every advertised capability and asserts the
//! *negative space* (unsupported ops error out) — so capability honesty is the
//! conformance contract, and a new engine cannot pass while lying about itself.
//!
//! Usage (see `tests/conformance.rs`): build the adapter under test with a mount
//! carrying an inline DSN (inline wins in the resolver, so no env map is
//! needed), then `run_suite(adapter, mount).await`.

use std::sync::Arc;

use data_plane_core::{
    CredentialRef, DataOperation, DataOperationKind, DatabaseMount, EngineAdapter,
    EngineCapabilities, EnginePool, IdentitySource, PoolPolicy, RawStatement, RequestIdentity,
    ReturningMode, TxBeginRequest,
};
use serde_json::{json, Value};

const RESOURCE: &str = "conf_probe";

/// Outcome of one conformance run.
#[derive(Debug, Default)]
pub struct SuiteReport {
    pub engine: String,
    pub passed: Vec<String>,
    pub failed: Vec<(String, String)>,
    pub skipped: Vec<String>,
}

impl SuiteReport {
    #[must_use]
    pub fn is_green(&self) -> bool {
        self.failed.is_empty()
    }

    fn record(&mut self, name: &str, outcome: Result<(), String>) {
        match outcome {
            Ok(()) => self.passed.push(name.to_string()),
            Err(e) => self.failed.push((name.to_string(), e)),
        }
    }

    fn skip(&mut self, name: &str, why: &str) {
        self.skipped.push(format!("{name} ({why})"));
    }
}

impl std::fmt::Display for SuiteReport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(f, "── conformance: {} ──", self.engine)?;
        for p in &self.passed {
            writeln!(f, "  PASS  {p}")?;
        }
        for s in &self.skipped {
            writeln!(f, "  SKIP  {s}")?;
        }
        for (name, why) in &self.failed {
            writeln!(f, "  FAIL  {name}: {why}")?;
        }
        write!(
            f,
            "  → {} passed, {} skipped, {} failed",
            self.passed.len(),
            self.skipped.len(),
            self.failed.len()
        )
    }
}

/// Run the full battery. Returns a report; `report.is_green()` is the gate.
pub async fn run_suite(adapter: Arc<dyn EngineAdapter>, mount: DatabaseMount) -> SuiteReport {
    let engine = adapter.engine().to_string();
    let caps = adapter.capabilities();
    let mut report = SuiteReport {
        engine: engine.clone(),
        ..Default::default()
    };

    let pool = match adapter.open_pool(mount.clone()).await {
        Ok(p) => p,
        Err(e) => {
            report
                .failed
                .push(("open_pool".to_string(), format!("{e}")));
            return report;
        }
    };
    let id = identity(&mount.tenant_id);

    // Bootstrap a scratch resource. Relational engines (caps.ddl) get an
    // explicit table — including the composite UNIQUE(owner_id, id) the
    // owner-scoped upsert arbitrates on; document/KV engines create on write.
    if let Some(ddl) = scratch_create_sql(&engine) {
        // Clear any unqualified shadow first (a prior run's table in the
        // `$user` schema would otherwise hide the public one from operations).
        if let Some(predrop) = scratch_predrop_sql(&engine) {
            let _ = raw(&*pool, predrop, &id).await;
        }
        if let Err(e) = raw(&*pool, ddl, &id).await {
            report
                .failed
                .push(("bootstrap".to_string(), format!("create scratch: {e}")));
            return report;
        }
    }
    // Best-effort clean slate (a prior aborted run may have left rows).
    let _ = pool
        .execute(
            op(
                DataOperationKind::Delete,
                json!({ "owner_id": id_owner(&id) }),
            ),
            id.clone(),
        )
        .await;

    report.record("crud", check_crud(&*pool, &id).await);
    if caps.upsert {
        report.record("upsert", check_upsert(&*pool, &id).await);
    } else {
        report.skip("upsert", "descriptor: upsert=false");
    }
    if caps.batch {
        report.record("batch", check_batch(&*pool, &id).await);
    } else {
        report.skip("batch", "descriptor: batch=false");
    }
    if caps.aggregate {
        report.record("aggregate", check_aggregate(&*pool, &id).await);
    } else {
        report.skip("aggregate", "descriptor: aggregate=false");
    }
    report.record(
        "filtering",
        check_filtering(&*pool, &id, &engine, &caps).await,
    );
    if caps.transactions {
        report.record(
            "transactions",
            check_transactions(&*pool, &mount, &id).await,
        );
    } else {
        report.skip("transactions", "descriptor: transactions=false");
    }
    if caps.introspect {
        report.record("introspect", check_introspect(&*pool, &id).await);
    } else {
        report.skip("introspect", "descriptor: introspect=false");
    }
    report.record("honesty", check_honesty(&*pool, &id, &caps).await);

    // Teardown (best effort).
    if let Some(drop_sql) = scratch_drop_sql(&engine) {
        let _ = raw(&*pool, drop_sql, &id).await;
    } else {
        let _ = pool
            .execute(
                op(
                    DataOperationKind::Delete,
                    json!({ "owner_id": id_owner(&id) }),
                ),
                id.clone(),
            )
            .await;
    }
    let _ = pool.close().await;
    report
}

// ── checks ───────────────────────────────────────────────────────────────────

async fn check_crud(pool: &dyn EnginePool, id: &RequestIdentity) -> Result<(), String> {
    pool.execute(
        insert(json!({ "id": "c1", "name": "before", "n": 1 })),
        id.clone(),
    )
    .await
    .map_err(|e| format!("insert: {e}"))?;
    let got = get_one(pool, id, "c1").await?;
    expect_field(&got, "name", "before")?;

    pool.execute(update("c1", json!({ "name": "after" })), id.clone())
        .await
        .map_err(|e| format!("update: {e}"))?;
    let got = get_one(pool, id, "c1").await?;
    expect_field(&got, "name", "after")?;

    pool.execute(
        op(DataOperationKind::Delete, json!({ "id": "c1" })),
        id.clone(),
    )
    .await
    .map_err(|e| format!("delete: {e}"))?;
    let r = pool
        .execute(get_op("c1"), id.clone())
        .await
        .map_err(|e| format!("get-after-delete: {e}"))?;
    if !r.rows.is_empty() {
        return Err("row still present after delete".into());
    }
    Ok(())
}

async fn check_upsert(pool: &dyn EnginePool, id: &RequestIdentity) -> Result<(), String> {
    pool.execute(
        upsert("u1", json!({ "id": "u1", "name": "one" })),
        id.clone(),
    )
    .await
    .map_err(|e| format!("upsert-insert: {e}"))?;
    pool.execute(
        upsert("u1", json!({ "id": "u1", "name": "two" })),
        id.clone(),
    )
    .await
    .map_err(|e| format!("upsert-update: {e}"))?;
    let got = get_one(pool, id, "u1").await?;
    expect_field(&got, "name", "two")?;
    pool.execute(
        op(DataOperationKind::Delete, json!({ "id": "u1" })),
        id.clone(),
    )
    .await
    .ok();
    Ok(())
}

async fn check_batch(pool: &dyn EnginePool, id: &RequestIdentity) -> Result<(), String> {
    // Clean batch: two inserts. The summary's `atomic` flag tells us which
    // failure-mode contract this engine declares — we then test exactly that.
    let clean = batch(vec![
        insert(json!({ "id": "b1", "name": "batch", "n": 1 })),
        insert(json!({ "id": "b2", "name": "batch", "n": 2 })),
    ]);
    let res = pool
        .execute(clean, id.clone())
        .await
        .map_err(|e| format!("clean batch: {e}"))?;
    let summary = res.batch.ok_or("clean batch returned no BatchSummary")?;
    if summary.items.len() != 2 {
        return Err(format!(
            "expected 2 item outcomes, got {}",
            summary.items.len()
        ));
    }
    let atomic = summary.atomic;

    // Universal poison: an empty-filter delete is refused as a mass-write on
    // every engine, so it fails mid-batch without depending on a dialect.
    let poison = op(DataOperationKind::Delete, json!({}));
    if atomic {
        // Atomic engine: the poison must roll the whole batch back.
        let res = pool
            .execute(
                batch(vec![
                    insert(json!({ "id": "b3", "name": "batch", "n": 3 })),
                    poison,
                ]),
                id.clone(),
            )
            .await;
        if res.is_ok() {
            return Err("atomic batch with a poison item unexpectedly succeeded".into());
        }
        let r = pool
            .execute(get_op("b3"), id.clone())
            .await
            .map_err(|e| format!("get b3: {e}"))?;
        if !r.rows.is_empty() {
            return Err("atomic batch leaked b3 (not rolled back)".into());
        }
    } else {
        // Ordered engine: item before the poison persists, item after skips.
        let res = pool
            .execute(
                batch(vec![
                    insert(json!({ "id": "o1", "name": "ordered" })),
                    poison,
                    insert(json!({ "id": "o3", "name": "ordered" })),
                ]),
                id.clone(),
            )
            .await
            .map_err(|e| format!("ordered batch: {e}"))?;
        let s = res.batch.ok_or("ordered batch returned no BatchSummary")?;
        if s.atomic {
            return Err("ordered engine reported atomic=true".into());
        }
        let before = pool
            .execute(get_op("o1"), id.clone())
            .await
            .map_err(|e| format!("get o1: {e}"))?;
        if before.rows.is_empty() {
            return Err("ordered batch lost the item before the failure (o1)".into());
        }
        let after = pool
            .execute(get_op("o3"), id.clone())
            .await
            .map_err(|e| format!("get o3: {e}"))?;
        if !after.rows.is_empty() {
            return Err("ordered batch executed the item after the failure (o3)".into());
        }
    }
    // Cleanup batch rows.
    for key in ["b1", "b2", "b3", "o1", "o3"] {
        let _ = pool
            .execute(
                op(DataOperationKind::Delete, json!({ "id": key })),
                id.clone(),
            )
            .await;
    }
    Ok(())
}

async fn check_aggregate(pool: &dyn EnginePool, id: &RequestIdentity) -> Result<(), String> {
    for n in 1..=3 {
        pool.execute(
            insert(json!({ "id": format!("a{n}"), "name": "agg", "n": n })),
            id.clone(),
        )
        .await
        .map_err(|e| format!("agg insert: {e}"))?;
    }
    let mut agg = op(
        DataOperationKind::Aggregate,
        json!({ "name": { "$eq": "agg" } }),
    );
    agg.aggregate = Some(
        serde_json::from_value(json!({
            "aggregates": [
                { "func": "count", "alias": "total" },
                { "func": "sum", "field": "n", "alias": "sum_n" }
            ]
        }))
        .unwrap(),
    );
    let r = pool
        .execute(agg, id.clone())
        .await
        .map_err(|e| format!("aggregate: {e}"))?;
    let row = r.rows.first().ok_or("aggregate returned no rows")?;
    if num(row, "total") != Some(3.0) {
        return Err(format!("count: expected 3, got {:?}", row.get("total")));
    }
    if num(row, "sum_n") != Some(6.0) {
        return Err(format!("sum: expected 6, got {:?}", row.get("sum_n")));
    }
    for n in 1..=3 {
        let _ = pool
            .execute(
                op(DataOperationKind::Delete, json!({ "id": format!("a{n}") })),
                id.clone(),
            )
            .await;
    }
    Ok(())
}

async fn check_filtering(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    engine: &str,
    caps: &EngineCapabilities,
) -> Result<(), String> {
    for (i, name) in [(1, "alpha"), (2, "beta"), (3, "gamma")] {
        pool.execute(
            insert(json!({ "id": format!("f{i}"), "name": name, "n": i })),
            id.clone(),
        )
        .await
        .map_err(|e| format!("filter insert: {e}"))?;
    }
    // limit/offset is portable across every engine that lists.
    let mut listed = op(
        DataOperationKind::List,
        json!({ "name": { "$eq": "beta" } }),
    );
    listed.limit = Some(10);
    // Rich field-filter + sort only where the engine advertises real query
    // power (relational + document); KV/passthrough get the basic list path.
    let rich = caps.ddl || engine == "mongodb";
    if !rich {
        let r = pool
            .execute(list_all(), id.clone())
            .await
            .map_err(|e| format!("list: {e}"))?;
        if r.rows.len() < 3 {
            return Err(format!("list returned {} rows, expected ≥3", r.rows.len()));
        }
    } else {
        let r = pool
            .execute(listed, id.clone())
            .await
            .map_err(|e| format!("eq filter: {e}"))?;
        if r.rows.len() != 1 {
            return Err(format!("eq filter: expected 1 row, got {}", r.rows.len()));
        }
        expect_field(&r.rows[0], "name", "beta")?;
        // sort + limit: highest n first, capped to 2.
        let mut sorted = op(
            DataOperationKind::List,
            json!({ "name": { "$eq": "alpha" } }),
        );
        sorted.filter = None;
        sorted.sort = Some(
            [("n".to_string(), "desc".to_string())]
                .into_iter()
                .collect(),
        );
        sorted.limit = Some(2);
        let r = pool
            .execute(sorted, id.clone())
            .await
            .map_err(|e| format!("sort: {e}"))?;
        if r.rows.len() != 2 {
            return Err(format!("sort+limit: expected 2 rows, got {}", r.rows.len()));
        }
        if num(&r.rows[0], "n") != Some(3.0) {
            return Err("sort desc: first row is not the highest n".into());
        }
    }
    for i in 1..=3 {
        let _ = pool
            .execute(
                op(DataOperationKind::Delete, json!({ "id": format!("f{i}") })),
                id.clone(),
            )
            .await;
    }
    Ok(())
}

async fn check_transactions(
    pool: &dyn EnginePool,
    mount: &DatabaseMount,
    id: &RequestIdentity,
) -> Result<(), String> {
    // commit visibility
    let tx = pool
        .begin(TxBeginRequest {
            identity: id.clone(),
            mount: mount.clone(),
            isolation: None,
            timeout_ms: None,
        })
        .await
        .map_err(|e| format!("begin: {e}"))?;
    tx.execute(
        insert(json!({ "id": "tx1", "name": "committed" })),
        id.clone(),
    )
    .await
    .map_err(|e| format!("tx insert: {e}"))?;
    tx.commit().await.map_err(|e| format!("commit: {e}"))?;
    let r = pool
        .execute(get_op("tx1"), id.clone())
        .await
        .map_err(|e| format!("get tx1: {e}"))?;
    if r.rows.is_empty() {
        return Err("committed row not visible after commit".into());
    }
    // rollback invisibility
    let tx = pool
        .begin(TxBeginRequest {
            identity: id.clone(),
            mount: mount.clone(),
            isolation: None,
            timeout_ms: None,
        })
        .await
        .map_err(|e| format!("begin2: {e}"))?;
    tx.execute(
        insert(json!({ "id": "tx2", "name": "rolledback" })),
        id.clone(),
    )
    .await
    .map_err(|e| format!("tx2 insert: {e}"))?;
    tx.rollback().await.map_err(|e| format!("rollback: {e}"))?;
    let r = pool
        .execute(get_op("tx2"), id.clone())
        .await
        .map_err(|e| format!("get tx2: {e}"))?;
    if !r.rows.is_empty() {
        return Err("rolled-back row is visible (rollback did not undo)".into());
    }
    let _ = pool
        .execute(
            op(DataOperationKind::Delete, json!({ "id": "tx1" })),
            id.clone(),
        )
        .await;
    Ok(())
}

async fn check_introspect(pool: &dyn EnginePool, id: &RequestIdentity) -> Result<(), String> {
    let schema = pool
        .describe_schema(id.clone())
        .await
        .map_err(|e| format!("describe_schema: {e}"))?;
    if !schema.tables.iter().any(|t| t.name == RESOURCE) {
        let seen: Vec<&str> = schema.tables.iter().map(|t| t.name.as_str()).collect();
        return Err(format!(
            "introspection did not surface '{RESOURCE}'; saw: {seen:?}"
        ));
    }
    Ok(())
}

/// Honesty: every op the descriptor says is UNSUPPORTED must error (the pool's
/// SUPPORTED_OPS gate), never silently succeed. The supported ops are proven by
/// the functional checks above — this guards the negative space.
async fn check_honesty(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    caps: &EngineCapabilities,
) -> Result<(), String> {
    for kind in DataOperationKind::ALL {
        if caps.supports_op(&kind) {
            continue;
        }
        let probe = op(kind.clone(), json!({ "id": "honesty" }));
        if pool.execute(probe, id.clone()).await.is_ok() {
            return Err(format!(
                "descriptor says {kind:?} is unsupported, but the pool served it"
            ));
        }
    }
    Ok(())
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn identity(tenant: &str) -> RequestIdentity {
    RequestIdentity {
        tenant_id: tenant.to_string(),
        project_id: None,
        app_id: None,
        user_id: Some(format!("conf-user-{tenant}")),
        roles: vec![],
        scopes: vec!["read".into(), "write".into()],
        source: IdentitySource::ServiceToken,
    }
}

fn id_owner(id: &RequestIdentity) -> String {
    id.user_id.clone().unwrap_or_else(|| id.tenant_id.clone())
}

/// Build a [`DatabaseMount`] for an engine with an inline DSN (resolver uses
/// it directly — no env map needed).
#[must_use]
pub fn mount_for(engine: &str, tenant: &str, dsn: &str) -> DatabaseMount {
    DatabaseMount {
        id: format!("conf-{engine}"),
        tenant_id: tenant.to_string(),
        project_id: None,
        engine: engine.to_string(),
        name: "conformance".to_string(),
        credential_ref: CredentialRef {
            provider: "inline".to_string(),
            reference: "-".to_string(),
            version: "1".to_string(),
        },
        pool_policy: PoolPolicy::default(),
        capability_overrides: None,
        inline_dsn: Some(dsn.to_string()),
        isolation: None,
        replica_inline_dsn: None,
        read_replica_route: false,
    }
}

fn op(kind: DataOperationKind, filter: Value) -> DataOperation {
    DataOperation {
        op: kind,
        resource: RESOURCE.to_string(),
        data: None,
        filter: Some(filter),
        sort: None,
        limit: None,
        offset: None,
        idempotency_key: None,
        expected_version: None,
        returning: Some(ReturningMode::Full),
        aggregate: None,
        fields: None,
        search: None,
        vector: None,
    }
}

fn insert(data: Value) -> DataOperation {
    let mut o = op(DataOperationKind::Insert, Value::Null);
    o.filter = None;
    o.data = Some(data);
    o
}

fn update(id: &str, data: Value) -> DataOperation {
    let mut o = op(DataOperationKind::Update, json!({ "id": id }));
    o.data = Some(data);
    o
}

fn upsert(id: &str, data: Value) -> DataOperation {
    let mut o = op(DataOperationKind::Upsert, json!({ "id": id }));
    o.data = Some(data);
    o
}

fn get_op(id: &str) -> DataOperation {
    op(DataOperationKind::Get, json!({ "id": id }))
}

fn list_all() -> DataOperation {
    let mut o = op(DataOperationKind::List, Value::Null);
    o.filter = None;
    o.limit = Some(50);
    o
}

fn batch(items: Vec<DataOperation>) -> DataOperation {
    let arr: Vec<Value> = items
        .into_iter()
        .map(|o| serde_json::to_value(o).unwrap())
        .collect();
    let mut o = op(DataOperationKind::Batch, Value::Null);
    o.filter = None;
    o.data = Some(Value::Array(arr));
    o
}

async fn get_one(pool: &dyn EnginePool, id: &RequestIdentity, key: &str) -> Result<Value, String> {
    let r = pool
        .execute(get_op(key), id.clone())
        .await
        .map_err(|e| format!("get {key}: {e}"))?;
    r.rows
        .into_iter()
        .next()
        .ok_or_else(|| format!("get {key}: no row"))
}

fn expect_field(row: &Value, field: &str, want: &str) -> Result<(), String> {
    match row.get(field).and_then(Value::as_str) {
        Some(v) if v == want => Ok(()),
        other => Err(format!("{field}: expected {want:?}, got {other:?}")),
    }
}

/// Numeric field tolerant of JSON number vs string (mysql DECIMAL → string).
fn num(row: &Value, field: &str) -> Option<f64> {
    row.get(field).and_then(|v| {
        v.as_f64()
            .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
    })
}

async fn raw(pool: &dyn EnginePool, sql: &str, id: &RequestIdentity) -> Result<(), String> {
    pool.execute_raw(
        RawStatement {
            statement: sql.to_string(),
            params: vec![],
            expect_rows: false,
        },
        id.clone(),
    )
    .await
    .map(|_| ())
    .map_err(|e| format!("{e}"))
}

/// Per-engine scratch DDL. Relational engines need an explicit table with the
/// composite UNIQUE(owner_id, id) the owner-scoped upsert arbitrates on. New
/// engines add their dialect here as part of onboarding. None ⇒ implicit
/// resource (mongo collection / redis keyspace).
fn scratch_create_sql(engine: &str) -> Option<&'static str> {
    match engine {
        // Qualify to `public`: the connection's default search_path is
        // `"$user", public`, and a `$user` schema (named after the DB user)
        // shadows public — an unqualified CREATE would land there, but
        // describe_schema scans `public`. Qualifying keeps create + describe in
        // the same schema; unqualified ops still resolve to it via search_path.
        "postgresql" | "cockroachdb" => Some(
            "CREATE TABLE IF NOT EXISTS public.conf_probe \
             (id text PRIMARY KEY, name text, n integer, owner_id text, UNIQUE (owner_id, id))",
        ),
        "mysql" | "mariadb" => Some(
            "CREATE TABLE IF NOT EXISTS conf_probe \
             (id varchar(64) PRIMARY KEY, name text, n int, owner_id varchar(255), \
              UNIQUE KEY owner_id_id (owner_id, id))",
        ),
        "sqlite" => Some(
            "CREATE TABLE IF NOT EXISTS conf_probe \
             (id text PRIMARY KEY, name text, n integer, owner_id text, UNIQUE (owner_id, id))",
        ),
        "mssql" => Some(
            "IF OBJECT_ID('conf_probe','U') IS NULL CREATE TABLE conf_probe \
             (id nvarchar(64) PRIMARY KEY, name nvarchar(max), n int, owner_id nvarchar(255), \
              CONSTRAINT uq_owner_id UNIQUE (owner_id, id))",
        ),
        _ => None,
    }
}

/// Best-effort pre-drop of an UNqualified scratch table that a prior run may
/// have left in the `$user` schema (postgres only — it would shadow the
/// `public` one in the search_path and split create/describe from operations).
fn scratch_predrop_sql(engine: &str) -> Option<&'static str> {
    match engine {
        "postgresql" | "cockroachdb" => Some("DROP TABLE IF EXISTS conf_probe"),
        _ => None,
    }
}

fn scratch_drop_sql(engine: &str) -> Option<&'static str> {
    match engine {
        "postgresql" | "cockroachdb" => Some("DROP TABLE IF EXISTS public.conf_probe"),
        "mysql" | "mariadb" | "sqlite" => Some("DROP TABLE IF EXISTS conf_probe"),
        "mssql" => Some("IF OBJECT_ID('conf_probe','U') IS NOT NULL DROP TABLE conf_probe"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── SuiteReport: the pass/fail aggregation that backs the gate ────────────

    #[test]
    fn empty_report_is_green() {
        assert!(SuiteReport::default().is_green());
    }

    #[test]
    fn is_green_tracks_only_failures() {
        let mut r = SuiteReport::default();
        r.record("crud", Ok(()));
        r.skip("transactions", "descriptor: transactions=false");
        assert!(r.is_green(), "passes + skips alone must stay green");
        r.record("honesty", Err("served an unsupported op".into()));
        assert!(!r.is_green(), "a single failure must turn the gate red");
    }

    #[test]
    fn record_routes_ok_and_err_to_distinct_buckets() {
        let mut r = SuiteReport::default();
        r.record("crud", Ok(()));
        r.record("upsert", Err("upsert-update: boom".into()));
        assert_eq!(r.passed, vec!["crud".to_string()]);
        assert_eq!(
            r.failed,
            vec![("upsert".to_string(), "upsert-update: boom".to_string())]
        );
        assert!(r.skipped.is_empty());
    }

    #[test]
    fn skip_formats_name_with_reason() {
        let mut r = SuiteReport::default();
        r.skip("batch", "descriptor: batch=false");
        assert_eq!(r.skipped, vec!["batch (descriptor: batch=false)".to_string()]);
    }

    #[test]
    fn display_renders_counts_and_each_outcome_line() {
        let mut r = SuiteReport {
            engine: "redis".to_string(),
            ..Default::default()
        };
        r.record("crud", Ok(()));
        r.skip("aggregate", "descriptor: aggregate=false");
        r.record("honesty", Err("leaked an op".into()));
        let out = r.to_string();
        assert!(out.contains("── conformance: redis ──"));
        assert!(out.contains("  PASS  crud"));
        assert!(out.contains("  SKIP  aggregate (descriptor: aggregate=false)"));
        assert!(out.contains("  FAIL  honesty: leaked an op"));
        assert!(out.contains("→ 1 passed, 1 skipped, 1 failed"));
    }

    // ── scratch DDL selection: the per-engine onboarding seam ─────────────────

    #[test]
    fn relational_engines_get_an_explicit_scratch_table() {
        // Every engine the descriptor marks `ddl`/relational must bootstrap an
        // explicit table carrying the composite UNIQUE(owner_id, id) the
        // owner-scoped upsert arbitrates on.
        for engine in ["postgresql", "cockroachdb", "mysql", "mariadb", "sqlite", "mssql"] {
            let ddl = scratch_create_sql(engine)
                .unwrap_or_else(|| panic!("{engine} must have scratch DDL"));
            assert!(ddl.contains("conf_probe"), "{engine}: targets the probe table");
            assert!(
                ddl.to_ascii_lowercase().contains("owner_id"),
                "{engine}: scratch table carries the owner_id column"
            );
        }
    }

    #[test]
    fn document_and_kv_engines_have_no_scratch_ddl() {
        // mongo (collection) / redis (keyspace) / http create on write → None.
        for engine in ["mongodb", "redis", "http", "dynamodb", "unknown"] {
            assert_eq!(
                scratch_create_sql(engine),
                None,
                "{engine}: implicit resource, no scratch DDL"
            );
        }
    }

    #[test]
    fn predrop_is_postgres_only() {
        // The unqualified `$user`-schema shadow only exists for postgres-family
        // search_path engines; every other engine needs no pre-drop.
        assert!(scratch_predrop_sql("postgresql").is_some());
        assert!(scratch_predrop_sql("cockroachdb").is_some());
        for engine in ["mysql", "sqlite", "mssql", "mongodb", "redis"] {
            assert_eq!(scratch_predrop_sql(engine), None, "{engine}");
        }
    }

    #[test]
    fn drop_sql_pairs_with_create_for_every_relational_engine() {
        // An engine that bootstraps an explicit table must also tear one down,
        // and the drop must target the same `conf_probe` resource.
        for engine in ["postgresql", "cockroachdb", "mysql", "mariadb", "sqlite", "mssql"] {
            let drop = scratch_drop_sql(engine)
                .unwrap_or_else(|| panic!("{engine} creates a table, so it must drop one"));
            assert!(drop.contains("conf_probe"), "{engine}: drops the probe table");
        }
        // Postgres qualifies to `public` on both create and drop so they land in
        // the same schema (the predrop handles the unqualified shadow).
        assert!(scratch_drop_sql("postgresql").unwrap().contains("public.conf_probe"));
        // Implicit-resource engines drop nothing.
        for engine in ["mongodb", "redis", "http"] {
            assert_eq!(scratch_drop_sql(engine), None, "{engine}");
        }
    }

    // ── pure identity / mount builders ────────────────────────────────────────

    #[test]
    fn mount_for_sets_inline_dsn_so_the_resolver_skips_the_env_map() {
        let m = mount_for("postgresql", "acme", "postgres://x/y");
        assert_eq!(m.engine, "postgresql");
        assert_eq!(m.tenant_id, "acme");
        assert_eq!(m.inline_dsn.as_deref(), Some("postgres://x/y"));
        assert_eq!(m.credential_ref.provider, "inline");
    }

    #[test]
    fn id_owner_prefers_user_id_then_falls_back_to_tenant() {
        // The conformance identity stamps a user_id, so the owner is per-user.
        assert_eq!(id_owner(&identity("acme")), "conf-user-acme");
        // With no user_id the tenant id is the owner (the documented fallback).
        let mut bare = identity("acme");
        bare.user_id = None;
        assert_eq!(id_owner(&bare), "acme");
    }
}
