//! PB API-rules engine, v1: substitution lowering.
//!
//! A rule string (`owner = @request.auth.id && status = 'open'`) is parsed
//! with the same PB filter grammar, with `@request.auth.<field>` resolved to
//! the CALLER's literal value at request time (guest → `""`/null). The result
//! is an engine filter:
//! - list/view → AND-merged into the query filter (rows the rule excludes
//!   simply don't exist for the caller — PB semantics);
//! - update/delete → AND-merged into the WHERE (0 affected → 404);
//! - create → evaluated IN MEMORY against the lowered would-be record.
//!
//! Anything v1 cannot faithfully evaluate (`@collection.*`, `:modifiers`,
//! `@request.body/query/headers`) fails CLOSED with an audit line — a rule
//! must never silently widen.

use serde_json::{json, Value};

use super::PbAuth;

/// The caller context a rule can reference (`@request.*`).
#[derive(Clone)]
pub(crate) struct RuleCtx {
    /// Shaped auth record (None for guests).
    pub auth: Option<Value>,
    pub superuser: bool,
    /// Submitted body (create/update rules: `@request.body.*`).
    pub body: Option<Value>,
    /// Query params as a flat object (`@request.query.*`).
    pub query: Value,
    /// Request headers, lowercased keys (`@request.headers.*`).
    pub headers: Value,
}

impl RuleCtx {
    pub(crate) fn from_auth(auth: &PbAuth, record: Option<Value>) -> Self {
        Self {
            auth: record,
            superuser: matches!(auth, PbAuth::Superuser),
            body: None,
            query: json!({}),
            headers: json!({}),
        }
    }

    /// Attach request headers (lowercased keys) — list/view/etc rules.
    pub(crate) fn with_headers(mut self, headers: &axum::http::HeaderMap) -> Self {
        self.headers = Value::Object(
            headers
                .iter()
                .filter_map(|(k, v)| v.to_str().ok().map(|v| (k.as_str().to_lowercase(), json!(v))))
                .collect(),
        );
        self
    }

    /// Attach query params (handlers that have a `Query` extractor).
    pub(crate) fn with_query(mut self, query: &std::collections::HashMap<String, String>) -> Self {
        self.query = Value::Object(query.iter().map(|(k, v)| (k.clone(), json!(v))).collect());
        self
    }

    /// Attach the submitted body (create/update rules).
    pub(crate) fn with_body(mut self, body: Value) -> Self {
        self.body = Some(body);
        self
    }

    pub(crate) fn resolve(&self, reference: &str) -> Option<Value> {
        // PB renders an absent `@request.*` value as the zero value (empty
        // string), so a reference into a configured namespace always resolves.
        if let Some(field) = reference.strip_prefix("@request.auth.") {
            return Some(zero_or(self.auth.as_ref().and_then(|a| nested(a, field))));
        }
        if let Some(field) = reference.strip_prefix("@request.body.") {
            return Some(zero_or(self.body.as_ref().and_then(|b| nested(b, field))));
        }
        if let Some(field) = reference.strip_prefix("@request.query.") {
            return Some(zero_or(nested(&self.query, field)));
        }
        if let Some(field) = reference.strip_prefix("@request.headers.") {
            // PB lowercases header names and uses `_` for `-`
            let key = field.replace('-', "_").to_lowercase();
            return Some(zero_or(nested(&self.headers, &key.replace('_', "-"))));
        }
        None
    }
}

/// Traverse a dotted path into a JSON value (`a.b.c`).
fn nested(v: &Value, path: &str) -> Option<Value> {
    let mut cur = v;
    for seg in path.split('.') {
        cur = cur.get(seg)?;
    }
    Some(cur.clone())
}

fn zero_or(v: Option<Value>) -> Value {
    v.unwrap_or_else(|| json!(""))
}

/// Outcome of lowering a rule for query-shaped ops.
pub(crate) enum Lowered {
    /// Superuser or empty rule: no extra constraint.
    Open,
    /// AND this engine-filter wire shape into the operation.
    Constrain(Value),
    /// The rule uses an advanced construct (`:modifier`, multi-value `?op`,
    /// `geoDistance()`) — it must be evaluated IN MEMORY per record. The
    /// caller fetches candidates (with `sql_prefilter`) and applies this.
    Memory(super::predicate::PbExpr),
    /// The rule folded to FALSE for this caller: list → empty, view/update/
    /// delete → 404, create → 400. Matches nothing, ever.
    Never,
    /// Locked (None rule, non-superuser).
    Deny,
}

/// Lower `rule` for the caller. `None` rule = locked (superuser only),
/// `""` = public, expression = parse + substitute.
pub(crate) fn lower_rule(rule: Option<&String>, ctx: &RuleCtx) -> Lowered {
    if ctx.superuser {
        return Lowered::Open;
    }
    let Some(raw) = rule else {
        return Lowered::Deny;
    };
    if raw.trim().is_empty() {
        return Lowered::Open;
    }
    match super::predicate::parse(raw, &|r| ctx.resolve(r)) {
        Ok(expr) => match expr.to_engine_filter() {
            Some(ast) => match ast.fold() {
                data_plane_core::Folded::AlwaysTrue => Lowered::Open,
                data_plane_core::Folded::AlwaysFalse => Lowered::Never,
                data_plane_core::Folded::Constrained => {
                    Lowered::Constrain(super::records::filter_to_wire(&ast))
                }
            },
            // advanced construct → in-memory evaluation
            None => Lowered::Memory(expr),
        },
        Err(e) => {
            tracing::warn!(target: "audit", event = "pb_rule_unparseable", rule = %raw, error = %e,
                "rule did not parse — failing CLOSED");
            Lowered::Deny
        }
    }
}

/// The rule as a parsed predicate (or Open/Deny sentinel) — the single-record
/// handlers fetch the target and `eval` this in memory, which uniformly
/// covers SQL-able AND advanced (`:modifier`/`?any`/`geoDistance`) rules.
pub(crate) enum RulePred {
    Open,
    Deny,
    Pred(super::predicate::PbExpr),
}

pub(crate) fn rule_pred(rule: Option<&String>, ctx: &RuleCtx) -> RulePred {
    if ctx.superuser {
        return RulePred::Open;
    }
    let Some(raw) = rule else {
        return RulePred::Deny;
    };
    if raw.trim().is_empty() {
        return RulePred::Open;
    }
    match super::predicate::parse(raw, &|r| ctx.resolve(r)) {
        Ok(e) => RulePred::Pred(e),
        Err(e) => {
            tracing::warn!(target: "audit", event = "pb_rule_unparseable", rule = %raw, error = %e,
                "rule did not parse — failing CLOSED");
            RulePred::Deny
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(auth: Option<Value>) -> RuleCtx {
        RuleCtx { auth, superuser: false, body: None, query: json!({}), headers: json!({}) }
    }

    #[test]
    fn lowers_auth_substitution() {
        let c = ctx(Some(json!({ "id": "user1user1user1" })));
        match lower_rule(Some(&"owner = @request.auth.id".to_string()), &c) {
            Lowered::Constrain(f) => {
                assert_eq!(f, json!({ "owner": { "$eq": "user1user1user1" } }));
            }
            _ => panic!("expected Constrain"),
        }
    }

    #[test]
    fn guest_substitutes_empty_and_locked_denies() {
        let g = ctx(None);
        match lower_rule(Some(&"owner = @request.auth.id".to_string()), &g) {
            Lowered::Constrain(f) => assert_eq!(f, json!({ "owner": { "$eq": "" } })),
            _ => panic!("guest still gets a (never-matching) constraint"),
        }
        assert!(matches!(lower_rule(None, &g), Lowered::Deny));
        assert!(matches!(lower_rule(Some(&String::new()), &g), Lowered::Open));
    }

    #[test]
    fn modifiers_route_to_memory_not_deny() {
        // :modifiers are now SUPPORTED — they route to in-memory evaluation
        let c = ctx(Some(json!({ "id": "u" })));
        assert!(matches!(
            lower_rule(Some(&"title:isset = true".to_string()), &c),
            Lowered::Memory(_)
        ));
        assert!(matches!(
            lower_rule(Some(&"tags:length > 0".to_string()), &c),
            Lowered::Memory(_)
        ));
    }

    #[test]
    fn request_namespaces_resolve() {
        // @request.body/query/headers now RESOLVE (repaired); an absent value
        // is the zero value, so the rule evaluates rather than failing closed
        let mut c = ctx(Some(json!({ "id": "u" })));
        c.body = Some(json!({ "owner": "u" }));
        // @request.body.owner = @request.auth.id → 'u' = 'u' → AlwaysTrue
        assert!(matches!(
            lower_rule(Some(&"@request.body.owner = @request.auth.id".to_string()), &c),
            Lowered::Open
        ));
        // a genuinely unknown @request namespace still fails closed
        assert!(matches!(
            lower_rule(Some(&"@request.nonsense.x = 1".to_string()), &c),
            Lowered::Deny
        ));
    }

}
