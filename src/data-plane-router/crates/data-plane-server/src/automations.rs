//! Phase D — server-backed automations on the Rust `/data/v1` bypass.
//!
//! A port of the query-router's `AutomationsService`: rules persisted per
//! (tenant, mount) in the control Postgres (`automation_rules`), evaluated AFTER
//! a successful bypass MUTATION. Fired ONLY on the bypass write path
//! (`emit_outbox = true`) so it never double-fires with the query-router, which
//! still runs automations inline on `/query/v1`.
//!
//! Scope of this slice: the `set_property` action — a loop-safe internal
//! follow-up write (the most common automation, e.g. "when row added, set
//! status"). It re-enters the engine through a DIRECT `pool.execute` (not
//! `run_query`), so it can never re-trigger automations. The `notify` (realtime)
//! and `webhook` (SSRF-guarded external POST) actions are intentionally deferred
//! to a follow-up that reuses the Go webhook-dispatcher's outbox-consumer +
//! SSRF guard — keeping the security-sensitive egress on one audited path.
//!
//! Dormant unless `DATA_PLANE_OUTBOX_DSN` is set (same control Postgres the
//! outbox uses), so it ships alongside the bypass without forcing the wiring.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use deadpool_postgres::{Config as PgConfig, Pool, Runtime};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio_postgres::NoTls;

use data_plane_core::{DataOperation, DataOperationKind, EnginePool, RequestIdentity};

const RULES_CACHE_TTL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Deserialize)]
struct Rule {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default = "default_true")]
    enabled: bool,
    table: String,
    trigger: String,
    #[serde(default)]
    condition: Option<Condition>,
    #[serde(default)]
    actions: Vec<Action>,
}

#[derive(Debug, Clone, Deserialize)]
struct Condition {
    column: String,
    operator: String,
    #[serde(default)]
    value: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
struct Action {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    column: Option<String>,
    #[serde(default)]
    value: Option<Value>,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    url: Option<String>,
}

fn default_true() -> bool {
    true
}

/// `row_added` → insert/upsert, `row_updated` → update/upsert, `row_deleted` → delete.
fn trigger_matches(trigger: &str, op: &str) -> bool {
    match trigger {
        "row_added" => op == "insert" || op == "upsert",
        "row_updated" => op == "update" || op == "upsert",
        "row_deleted" => op == "delete",
        _ => false,
    }
}

/// Server-side condition evaluator over the written row — a faithful port of the
/// query-router's `evaluateCondition` (unknown columns make every operator but
/// `is_empty` false; `equals` is loose to bridge engine wire-type differences).
fn evaluate_condition(row: &Value, cond: &Condition) -> bool {
    let value = row.get(&cond.column);
    let empty = matches!(value, None | Some(Value::Null))
        || matches!(value, Some(Value::String(s)) if s.is_empty());
    match cond.operator.as_str() {
        "is_empty" => empty,
        "is_not_empty" => !empty,
        "equals" => loose_eq(value, cond.value.as_ref()),
        "not_equals" => !loose_eq(value, cond.value.as_ref()),
        "contains" => to_lossy(value)
            .to_lowercase()
            .contains(&to_lossy(cond.value.as_ref()).to_lowercase()),
        "greater_than" => as_f64(value) > as_f64(cond.value.as_ref()),
        "less_than" => as_f64(value) < as_f64(cond.value.as_ref()),
        _ => false,
    }
}

fn loose_eq(a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) if a == b => true,
        (Some(a), Some(b)) => to_lossy(Some(a)) == to_lossy(Some(b)),
        _ => false,
    }
}

fn to_lossy(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn as_f64(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(f64::NAN),
        Some(Value::String(s)) => s.parse().unwrap_or(f64::NAN),
        _ => f64::NAN,
    }
}

/// Reads automation rules from the control Postgres + fires `set_property`
/// follow-up writes. Cloneable-cheap (pool is an Arc; cache is a Mutex).
pub struct AutomationEngine {
    pool: Pool,
    cache: Mutex<HashMap<String, (Instant, Vec<Rule>)>>,
    /// Realtime publish endpoint for `notify` actions (best-effort).
    realtime_url: Option<String>,
    /// Short-timeout, redirect-free client for notify/webhook fan-out.
    /// Redirects are DISABLED so a public webhook target cannot 302 the
    /// request to an internal address after the SSRF check passed.
    http: reqwest::Client,
}

impl AutomationEngine {
    /// Build from `DATA_PLANE_OUTBOX_DSN` (the control Postgres). `None` (→ no
    /// automations) when unset, so the bypass works without it.
    #[must_use]
    pub fn from_env() -> Option<Self> {
        let dsn = std::env::var("DATA_PLANE_OUTBOX_DSN")
            .ok()
            .filter(|s| !s.trim().is_empty())?;
        let mut cfg = PgConfig::new();
        cfg.url = Some(dsn);
        let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls).ok()?;
        let realtime_url = std::env::var("REALTIME_PUBLISH_URL")
            .ok()
            .filter(|s| !s.trim().is_empty());
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .ok()?;
        Some(Self {
            pool,
            cache: Mutex::new(HashMap::new()),
            realtime_url,
            http,
        })
    }

    async fn list_rules(&self, tenant: &str, db_id: &str) -> Result<Vec<Rule>, String> {
        let key = format!("{tenant}:{db_id}");
        if let Ok(cache) = self.cache.lock() {
            if let Some((at, rules)) = cache.get(&key) {
                if at.elapsed() < RULES_CACHE_TTL {
                    return Ok(rules.clone());
                }
            }
        }
        let client = self
            .pool
            .get()
            .await
            .map_err(|e| format!("automations pool checkout: {e}"))?;
        let row = client
            .query_opt(
                // Compare db_id as text so the param is inferred as text (binding
                // a &str to a uuid-inferred param fails to serialize).
                "SELECT rules FROM automation_rules WHERE tenant_id = $1 AND db_id::text = $2",
                &[&tenant, &db_id],
            )
            .await
            .map_err(|e| format!("automations query: {e}"))?;
        let rules: Vec<Rule> = match row {
            Some(r) => serde_json::from_value(r.get::<_, Value>(0)).unwrap_or_default(),
            None => Vec::new(),
        };
        if let Ok(mut cache) = self.cache.lock() {
            cache.insert(key, (Instant::now(), rules.clone()));
        }
        Ok(rules)
    }

    /// Evaluate every rule for one successful bypass write and fire the
    /// `set_property` follow-ups. Best-effort: a rule failure is logged, never
    /// surfaced (the write is already committed). `notify`/`webhook` actions are
    /// deferred (see module docs) and skipped here.
    pub async fn run_for_write(
        &self,
        pool: &dyn EnginePool,
        identity: &RequestIdentity,
        db_id: &str,
        table: &str,
        op: &str,
        row: &Value,
        pk: Option<&Value>,
    ) {
        let rules = match self.list_rules(&identity.tenant_id, db_id).await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(target: "audit", event = "automation_rules_error", tenant = %identity.tenant_id, db = %db_id, "rules lookup failed: {e}");
                return;
            }
        };
        if !rules.is_empty() {
            tracing::info!(target: "audit", event = "automation_eval", tenant = %identity.tenant_id, db = %db_id, table = %table, op = %op, rules = rules.len(), "evaluating automation rules");
        }
        for rule in &rules {
            if !rule.enabled || rule.table != table || !trigger_matches(&rule.trigger, op) {
                continue;
            }
            if let Some(cond) = &rule.condition {
                if !evaluate_condition(row, cond) {
                    continue;
                }
            }
            for action in &rule.actions {
                match action.kind.as_str() {
                    "set_property" => {
                        self.fire_set_property(pool, identity, table, op, row, pk, action)
                            .await;
                    }
                    "notify" => {
                        self.fire_notify(identity, db_id, table, rule, action, row, pk)
                            .await;
                    }
                    "webhook" => {
                        self.fire_webhook(identity, db_id, table, op, rule, action, row, pk)
                            .await;
                    }
                    _ => {}
                }
            }
        }
    }

    async fn fire_set_property(
        &self,
        pool: &dyn EnginePool,
        identity: &RequestIdentity,
        table: &str,
        op: &str,
        row: &Value,
        pk: Option<&Value>,
        action: &Action,
    ) {
        if op == "delete" {
            return;
        }
        let Some(column) = action.column.as_deref() else {
            return;
        };
        let pk_val = pk
            .cloned()
            .or_else(|| row.get("id").cloned())
            .or_else(|| row.get("_id").cloned());
        let Some(pk_val) = pk_val else {
            return; // no primary key to target — skip (matches the TS)
        };
        let value = action.value.clone().unwrap_or(Value::Null);
        let follow_up = DataOperation {
            op: DataOperationKind::Update,
            resource: table.to_string(),
            data: Some(json!({ column: value })),
            filter: Some(json!({ "id": pk_val })),
            sort: None,
            limit: None,
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        // DIRECT pool execute (not run_query) → the follow-up never re-triggers
        // automations (loop safety). Owner-stamped with the SAME identity.
        match pool.execute(follow_up, identity.clone()).await {
            Ok(r) => tracing::info!(
                target: "audit",
                event = "automation_fired",
                tenant = %identity.tenant_id,
                table = %table,
                column = %column,
                affected = r.affected_rows,
                "set_property follow-up applied"
            ),
            Err(e) => tracing::warn!(
                target: "audit",
                event = "automation_failed",
                tenant = %identity.tenant_id,
                table = %table,
                column = %column,
                "set_property follow-up write failed: {e}"
            ),
        }
    }
}

impl AutomationEngine {
    /// `notify` → realtime publish, the same envelope the query-router's
    /// `publishAutomationFired` sends: topic `table:<dbId>:<table>`, event
    /// `automation_fired`, payload {dbId, table, ruleId, ruleName, message,
    /// pk, ts}. Best-effort: failure is logged, never surfaced.
    async fn fire_notify(
        &self,
        identity: &RequestIdentity,
        db_id: &str,
        table: &str,
        rule: &Rule,
        action: &Action,
        row: &Value,
        pk: Option<&Value>,
    ) {
        let Some(url) = self.realtime_url.as_deref() else {
            return; // no realtime endpoint configured — notify is a no-op
        };
        let pk_val = pk
            .cloned()
            .or_else(|| row.get("id").cloned())
            .or_else(|| row.get("_id").cloned())
            .unwrap_or(Value::Null);
        let message = action
            .message
            .clone()
            .or_else(|| rule.name.clone())
            .unwrap_or_else(|| "automation fired".to_string());
        let body = json!({
            "topic": format!("table:{db_id}:{table}"),
            "event_type": "automation_fired",
            "payload": {
                "dbId": db_id,
                "table": table,
                "ruleId": rule.id,
                "ruleName": rule.name,
                "message": message,
                "pk": pk_val,
                "ts": chrono::Utc::now().to_rfc3339(),
            },
        });
        match self.http.post(url).json(&body).send().await {
            Ok(r) if r.status().is_success() => tracing::info!(
                target: "audit", event = "automation_notify",
                tenant = %identity.tenant_id, db = %db_id, table = %table,
                "notify published to realtime"
            ),
            Ok(r) => tracing::warn!(
                target: "audit", event = "automation_notify_failed",
                tenant = %identity.tenant_id, table = %table, status = %r.status(),
                "realtime publish rejected"
            ),
            Err(e) => tracing::warn!(
                target: "audit", event = "automation_notify_failed",
                tenant = %identity.tenant_id, table = %table,
                "realtime publish error: {e}"
            ),
        }
    }

    /// `webhook` → HTTPS-only POST to a PUBLIC address: the URL passes the same
    /// SSRF guard as the http engine adapter (private/link-local/metadata
    /// blocked, every resolved IP validated and PINNED — and the client never
    /// follows redirects, so a public 302 cannot bounce the call inward).
    /// Payload mirrors the query-router: {rule:{id,name}, dbId, table, op, pk, ts}.
    #[allow(clippy::too_many_arguments)]
    async fn fire_webhook(
        &self,
        identity: &RequestIdentity,
        db_id: &str,
        table: &str,
        op: &str,
        rule: &Rule,
        action: &Action,
        row: &Value,
        pk: Option<&Value>,
    ) {
        let Some(url) = action.url.as_deref().filter(|u| !u.trim().is_empty()) else {
            return;
        };
        if !url.to_ascii_lowercase().starts_with("https://") {
            tracing::warn!(
                target: "audit", event = "automation_webhook_blocked",
                tenant = %identity.tenant_id, table = %table,
                "webhook rejected: https-only"
            );
            return;
        }
        let pinned = match data_plane_pool::guard_and_resolve(url).await {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(
                    target: "audit", event = "automation_webhook_blocked",
                    tenant = %identity.tenant_id, table = %table,
                    "webhook rejected by SSRF guard: {e}"
                );
                return;
            }
        };
        let pk_val = pk
            .cloned()
            .or_else(|| row.get("id").cloned())
            .or_else(|| row.get("_id").cloned())
            .unwrap_or(Value::Null);
        let body = json!({
            "rule": { "id": rule.id, "name": rule.name },
            "dbId": db_id,
            "table": table,
            "op": op,
            "pk": pk_val,
            "ts": chrono::Utc::now().to_rfc3339(),
        });
        // Pin the request to the validated IPs (anti-DNS-rebind), mirroring the
        // http engine adapter. A fresh client per fire is fine at automation rates.
        let client = match &pinned {
            Some((host, addrs)) => {
                let mut b = reqwest::Client::builder()
                    .timeout(Duration::from_secs(5))
                    .redirect(reqwest::redirect::Policy::none());
                for addr in addrs {
                    b = b.resolve(host, *addr);
                }
                match b.build() {
                    Ok(c) => c,
                    Err(_) => return,
                }
            }
            None => self.http.clone(), // dev escape (DATA_PLANE_HTTP_ALLOW_INTERNAL=1)
        };
        match client.post(url).json(&body).send().await {
            Ok(r) if r.status().is_success() => tracing::info!(
                target: "audit", event = "automation_webhook",
                tenant = %identity.tenant_id, db = %db_id, table = %table,
                "webhook delivered"
            ),
            Ok(r) => tracing::warn!(
                target: "audit", event = "automation_webhook_failed",
                tenant = %identity.tenant_id, table = %table, status = %r.status(),
                "webhook target rejected the POST"
            ),
            Err(e) => tracing::warn!(
                target: "audit", event = "automation_webhook_failed",
                tenant = %identity.tenant_id, table = %table,
                "webhook delivery error: {e}"
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trigger_op_mapping() {
        assert!(trigger_matches("row_added", "insert"));
        assert!(trigger_matches("row_added", "upsert"));
        assert!(!trigger_matches("row_added", "update"));
        assert!(trigger_matches("row_updated", "update"));
        assert!(trigger_matches("row_updated", "upsert"));
        assert!(trigger_matches("row_deleted", "delete"));
        assert!(!trigger_matches("row_deleted", "insert"));
        assert!(!trigger_matches("nonsense", "insert"));
    }

    fn cond(column: &str, operator: &str, value: Option<Value>) -> Condition {
        Condition {
            column: column.into(),
            operator: operator.into(),
            value,
        }
    }

    #[test]
    fn condition_evaluator_matches_ts_semantics() {
        let row = json!({ "status": "open", "count": 5, "note": "" });
        assert!(evaluate_condition(&row, &cond("note", "is_empty", None)));
        assert!(evaluate_condition(&row, &cond("missing", "is_empty", None)));
        assert!(evaluate_condition(
            &row,
            &cond("status", "is_not_empty", None)
        ));
        assert!(evaluate_condition(
            &row,
            &cond("status", "equals", Some(json!("open")))
        ));
        // loose equality bridges wire types (5 == "5")
        assert!(evaluate_condition(
            &row,
            &cond("count", "equals", Some(json!("5")))
        ));
        assert!(evaluate_condition(
            &row,
            &cond("count", "greater_than", Some(json!(3)))
        ));
        assert!(!evaluate_condition(
            &row,
            &cond("count", "less_than", Some(json!(3)))
        ));
        assert!(evaluate_condition(
            &row,
            &cond("status", "contains", Some(json!("PE")))
        ));
        assert!(!evaluate_condition(
            &row,
            &cond("status", "not_equals", Some(json!("open")))
        ));
        // unknown operator → false
        assert!(!evaluate_condition(&row, &cond("status", "bogus", None)));
    }
}
