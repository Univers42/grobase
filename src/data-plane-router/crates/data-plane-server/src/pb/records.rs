//! PB records API: `/api/collections/{collection}/records[...]`.
//!
//! List/view/create/update/delete in PB envelopes over the native engine.
//! Row shaping is TYPE-AWARE: SQLite hands back 0/1 for bools and TEXT for
//! json/multi-value fields — the facade renders what PB renders (real
//! booleans, parsed json, arrays for multi-select/file/relation, zero values
//! for NULL: `""`/`0`/`false`/`[]`).
//!
//! Access model at this phase: a NULL rule = superuser-only and `""` =
//! public — exactly PB's lock semantics. Non-empty rule STRINGS (the filter
//! expressions) are enforced by the Phase K rules engine; until it lands
//! they fail CLOSED (treated as locked) rather than silently allowing.

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use data_plane_core::{DataOperation, DataOperationKind};
use serde_json::{json, Map as JsonMap, Value};
use std::collections::HashMap;

use super::collections::Collection;
use super::{exec, pb_auth, pb_err, pb_id, pb_now, pb_of, PbAuth};
use crate::routes::AppState;

// ─── access rules (J-phase subset; K replaces with the full engine) ─────────

enum Rule<'a> {
    Locked,
    Public,
    /// The rule expression — evaluated by the Phase K rules engine; until
    /// then `Expr` fails closed (see `allowed`).
    #[allow(dead_code)]
    Expr(&'a str),
}

fn rule_of(raw: Option<&String>) -> Rule<'_> {
    match raw {
        None => Rule::Locked,
        Some(s) if s.trim().is_empty() => Rule::Public,
        Some(s) => Rule::Expr(s),
    }
}

/// Resolve the caller + their auth record once per request (rule context).
async fn caller(state: &AppState, headers: &header::HeaderMap) -> (PbAuth, super::rules::RuleCtx) {
    let auth = pb_auth(state, headers);
    let record = super::auth::auth_record_of(state, &auth).await;
    let ctx = super::rules::RuleCtx::from_auth(&auth, record).with_headers(headers);
    (auth, ctx)
}

// ─── type-aware row shaping ──────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum FieldKind {
    Text,
    Number,
    Bool,
    Json,
    Multi, // select/file/relation with maxSelect > 1 → JSON array in TEXT
    Single,
    Autodate, // server-stamped datetime; renders as text
    Password, // argon2id hash column; write-only
}

fn field_kinds(col: &Collection) -> HashMap<String, FieldKind> {
    let mut map = HashMap::new();
    if let Some(fields) = col.fields.as_array() {
        for f in fields {
            let name = f.get("name").and_then(|v| v.as_str()).unwrap_or_default();
            let ftype = f.get("type").and_then(|v| v.as_str()).unwrap_or_default();
            let max_select = f.get("maxSelect").and_then(Value::as_i64).unwrap_or(1);
            let kind = match ftype {
                "number" => FieldKind::Number,
                "bool" => FieldKind::Bool,
                "json" | "geoPoint" => FieldKind::Json,
                "select" | "file" | "relation" if max_select > 1 => FieldKind::Multi,
                "select" | "file" | "relation" => FieldKind::Single,
                "autodate" => FieldKind::Autodate,
                "password" => FieldKind::Password,
                _ => FieldKind::Text,
            };
            map.insert(name.to_string(), kind);
        }
    }
    map
}

/// Declared autodate fields → (name, onCreate, onUpdate). PB stamps these
/// server-side; clients can never set them.
fn autodates(col: &Collection) -> Vec<(String, bool, bool)> {
    col.fields
        .as_array()
        .map(|fields| {
            fields
                .iter()
                .filter(|f| f.get("type").and_then(|v| v.as_str()) == Some("autodate"))
                .filter_map(|f| {
                    let name = f.get("name").and_then(|v| v.as_str())?;
                    let on_create = f.get("onCreate").and_then(Value::as_bool).unwrap_or(true);
                    let on_update = f.get("onUpdate").and_then(Value::as_bool).unwrap_or(false);
                    Some((name.to_string(), on_create, on_update))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Engine row → PB record (typed values, zero defaults, collection stamps).
fn shape_record(col: &Collection, kinds: &HashMap<String, FieldKind>, row: &Value) -> Value {
    let mut out = JsonMap::new();
    out.insert("collectionId".into(), json!(col.id));
    out.insert("collectionName".into(), json!(col.name));
    let empty = JsonMap::new();
    let row_map = row.as_object().unwrap_or(&empty);
    for (name, kind) in kinds {
        let stored = row_map.get(name).cloned().unwrap_or(Value::Null);
        let shaped = match kind {
            FieldKind::Number => match stored {
                Value::Number(n) => Value::Number(n),
                Value::Null => json!(0),
                other => other,
            },
            FieldKind::Bool => match stored {
                Value::Number(n) => Value::Bool(n.as_i64().unwrap_or(0) != 0),
                Value::Bool(b) => Value::Bool(b),
                _ => Value::Bool(false),
            },
            FieldKind::Json => match &stored {
                Value::String(s) => serde_json::from_str(s).unwrap_or(Value::Null),
                Value::Null => Value::Null,
                other => other.clone(),
            },
            FieldKind::Multi => match &stored {
                Value::String(s) => serde_json::from_str(s).unwrap_or_else(|_| json!([])),
                Value::Null => json!([]),
                other => other.clone(),
            },
            FieldKind::Single | FieldKind::Text | FieldKind::Autodate => match stored {
                Value::Null => json!(""),
                other => other,
            },
            FieldKind::Password => continue, // write-only, never serialized
        };
        out.insert(name.clone(), shaped);
    }
    Value::Object(out)
}

/// Request body → engine data: keep only declared fields, lower typed values
/// to their storage form (bool→0/1 handled by the driver; json/multi →
/// canonical TEXT). Unknown keys are ignored, like PB.
fn lower_body(
    kinds: &HashMap<String, FieldKind>,
    body: &Value,
) -> Result<JsonMap<String, Value>, String> {
    let mut out = JsonMap::new();
    let Some(map) = body.as_object() else {
        return Err("body must be a JSON object".into());
    };
    for (k, v) in map {
        let Some(kind) = kinds.get(k.as_str()) else {
            continue;
        };
        if matches!(kind, FieldKind::Autodate | FieldKind::Password) {
            continue; // server-managed (stamped / hashed), never raw client input
        }
        let lowered = match kind {
            FieldKind::Json | FieldKind::Multi => match v {
                Value::Null => Value::Null,
                other => Value::String(other.to_string()),
            },
            _ => v.clone(),
        };
        out.insert(k.clone(), lowered);
    }
    Ok(out)
}

// ─── query params ────────────────────────────────────────────────────────────

/// `?sort=-created,name` → ordered (column, direction) pairs. `@random` and
/// `@rowid` are PB specials; `@random` has no stable PB-faithful lowering in
/// the shared op (and PB documents it as random) — lowered to rowid for now.
fn parse_sort(
    raw: &str,
    kinds: &HashMap<String, FieldKind>,
    any_safe_ident: bool,
) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    for part in raw.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let (dir, name) = match part.strip_prefix('-') {
            Some(rest) => ("desc", rest),
            None => ("asc", part.strip_prefix('+').unwrap_or(part)),
        };
        let column = match name {
            "@rowid" | "@random" => "rowid".to_string(),
            "id" => name.to_string(),
            other if kinds.contains_key(other) => other.to_string(),
            // views: columns come from the SELECT, unknown to the registry —
            // any safe identifier is allowed (quoted, parameter-free)
            other
                if any_safe_ident
                    && !other.is_empty()
                    && other.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') =>
            {
                other.to_string()
            }
            other => return Err(format!("unknown sort field '{other}'")),
        };
        out.push((column, dir.to_string()));
    }
    Ok(out)
}

/// Public alias for sibling modules (auth) that build raw ops.
pub(crate) fn base_op_pub(kind: DataOperationKind, resource: &str) -> DataOperation {
    base_op(kind, resource)
}

fn base_op(kind: DataOperationKind, resource: &str) -> DataOperation {
    DataOperation {
        op: kind,
        resource: resource.to_string(),
        data: None,
        filter: None,
        sort: None,
        limit: None,
        offset: None,
        idempotency_key: None,
        expected_version: None,
        returning: None,
        aggregate: None,
        fields: None,
        // grobase DataOperation has no declaration-ordered `sort_order`; the pb
        // facade maps PB's signed sort into the engine's `sort` BTreeMap below.
        search: None,
        vector: None,
    }
}

/// Translate `?filter=` via the PB DSL parser into the engine filter wire
/// shape (the engine re-validates; this just bridges grammars).
#[cfg(test)]
fn filter_wire(raw: &str) -> Result<Option<Value>, String> {
    if raw.trim().is_empty() {
        return Ok(None);
    }
    let ast = super::filter::parse_pb_filter(raw)?;
    Ok(Some(filter_to_wire(&ast)))
}

pub(crate) fn filter_to_wire(f: &data_plane_core::Filter) -> Value {
    use data_plane_core::{CmpOp, Filter};
    match f {
        Filter::And(parts) => {
            json!({ "$and": parts.iter().map(filter_to_wire).collect::<Vec<_>>() })
        }
        Filter::Or(parts) => json!({ "$or": parts.iter().map(filter_to_wire).collect::<Vec<_>>() }),
        Filter::Not(inner) => json!({ "$not": filter_to_wire(inner) }),
        Filter::Cmp { field, op, value } => {
            let key = match op {
                CmpOp::Eq => "$eq",
                CmpOp::Ne => "$ne",
                CmpOp::Lt => "$lt",
                CmpOp::Lte => "$lte",
                CmpOp::Gt => "$gt",
                CmpOp::Gte => "$gte",
            };
            json!({ field: { key: value } })
        }
        Filter::In { field, values } => json!({ field: { "$in": values } }),
        Filter::Like { field, pattern, ci } => {
            let key = if *ci { "$ilike" } else { "$like" };
            json!({ field: { key: pattern } })
        }
        Filter::Between { field, low, high } => json!({ field: { "$between": [low, high] } }),
        Filter::IsNull { field, negate } => json!({ field: { "$null": !negate } }),
    }
}

// ─── expand (relations + back-relations) ─────────────────────────────────────

/// Declared relation fields → (field name, target collection id/name, multi).
fn relation_fields(col: &Collection) -> Vec<(String, String, bool)> {
    col.fields
        .as_array()
        .map(|fields| {
            fields
                .iter()
                .filter(|f| f.get("type").and_then(Value::as_str) == Some("relation"))
                .filter_map(|f| {
                    let name = f.get("name").and_then(Value::as_str)?.to_string();
                    let target = f.get("collectionId").and_then(Value::as_str)?.to_string();
                    let multi = f.get("maxSelect").and_then(Value::as_i64).unwrap_or(1) > 1;
                    Some((name, target, multi))
                })
                .collect()
        })
        .unwrap_or_default()
}

enum Link {
    Forward { multi: bool },
    Back { via: String },
}

/// PB's `?expand=` — comma-separated dot paths over relation fields, plus
/// `X_via_field` back-relations; ≤ 6 levels. Expanded records honor the
/// TARGET collection's viewRule for the caller (unexpandable → omitted,
/// exactly PB). Attached under `record.expand.{token}`.
async fn apply_expand(
    state: &AppState,
    col: &Collection,
    items: &mut [Value],
    expand_raw: &str,
    ctx: &super::rules::RuleCtx,
    depth: usize,
) {
    if depth > 6 || items.is_empty() {
        return;
    }
    let Ok(pb) = pb_of(state) else { return };
    for token in expand_raw
        .split(',')
        .map(str::trim)
        .filter(|t| !t.is_empty())
    {
        let (head, rest) = match token.split_once('.') {
            Some((h, r)) => (h, Some(r)),
            None => (token, None),
        };
        let (target_col, link): (Collection, Link) = if let Some((_, target, multi)) =
            relation_fields(col).into_iter().find(|(n, _, _)| n == head)
        {
            match pb.col_get(&target) {
                Some(t) => (t, Link::Forward { multi }),
                None => continue,
            }
        } else if let Some((tname, via)) = head.rsplit_once("_via_") {
            match pb.col_get(tname) {
                Some(t) => (
                    t,
                    Link::Back {
                        via: via.to_string(),
                    },
                ),
                None => continue,
            }
        } else {
            continue;
        };
        let (rule_filter, rule_mem) =
            match super::rules::lower_rule(target_col.view_rule.as_ref(), ctx) {
                super::rules::Lowered::Open => (None, None),
                super::rules::Lowered::Constrain(f) => (Some(f), None),
                super::rules::Lowered::Memory(e) => {
                    (e.sql_prefilter().map(|x| filter_to_wire(&x)), Some(e))
                }
                // locked/never: PB omits the expansion
                super::rules::Lowered::Never | super::rules::Lowered::Deny => continue,
            };
        let target_kinds = field_kinds(&target_col);

        let mut fetched: Vec<Value> = Vec::new();
        match &link {
            Link::Forward { .. } => {
                let mut ids: Vec<Value> = Vec::new();
                for item in items.iter() {
                    match item.get(head) {
                        Some(Value::String(id)) if !id.is_empty() => ids.push(json!(id)),
                        Some(Value::Array(a)) => ids.extend(a.iter().cloned()),
                        _ => {}
                    }
                }
                ids.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
                ids.dedup();
                if ids.is_empty() {
                    continue;
                }
                let mut op = base_op(DataOperationKind::List, &target_col.name);
                op.limit = Some(1000);
                let base = json!({ "id": { "$in": ids } });
                op.filter = Some(match rule_filter {
                    Some(rf) => json!({ "$and": [base, rf] }),
                    None => base,
                });
                if let Ok(r) = exec(state, op).await {
                    fetched = r.rows;
                }
            }
            Link::Back { via } => {
                let ids: Vec<Value> = items.iter().filter_map(|i| i.get("id").cloned()).collect();
                if ids.is_empty() {
                    continue;
                }
                let mut op = base_op(DataOperationKind::List, &target_col.name);
                op.limit = Some(1000);
                let mut base_map = serde_json::Map::new();
                base_map.insert(via.clone(), json!({ "$in": ids }));
                let base = Value::Object(base_map);
                op.filter = Some(match rule_filter {
                    Some(rf) => json!({ "$and": [base, rf] }),
                    None => base,
                });
                if let Ok(r) = exec(state, op).await {
                    fetched = r.rows;
                }
            }
        }
        let mut shaped: Vec<Value> = fetched
            .iter()
            .map(|r| shape_record(&target_col, &target_kinds, r))
            .collect();
        if let Some(e) = &rule_mem {
            let mut kept: Vec<Value> = Vec::new();
            for rec in shaped.into_iter() {
                if eval_access(state, e, &rec).await {
                    kept.push(rec);
                }
            }
            shaped = kept;
        }
        if let Some(rest) = rest {
            Box::pin(apply_expand(
                state,
                &target_col,
                &mut shaped,
                rest,
                ctx,
                depth + 1,
            ))
            .await;
        }
        let by_id: HashMap<String, Value> = shaped
            .into_iter()
            .filter_map(|r| Some((r.get("id")?.as_str()?.to_string(), r)))
            .collect();

        for item in items.iter_mut() {
            let attached: Option<Value> = match &link {
                Link::Forward { multi } => match item.get(head) {
                    Some(Value::String(id)) => by_id.get(id.as_str()).cloned(),
                    Some(Value::Array(a)) => {
                        let v: Vec<Value> = a
                            .iter()
                            .filter_map(|id| by_id.get(id.as_str()?).cloned())
                            .collect();
                        (!v.is_empty() || *multi).then_some(Value::Array(v))
                    }
                    _ => None,
                },
                Link::Back { via } => {
                    let my_id = item.get("id").and_then(Value::as_str).unwrap_or_default();
                    let v: Vec<Value> = by_id
                        .values()
                        .filter(|r| match r.get(via) {
                            Some(Value::String(s)) => s == my_id,
                            Some(Value::Array(a)) => a.iter().any(|x| x.as_str() == Some(my_id)),
                            _ => false,
                        })
                        .cloned()
                        .collect();
                    (!v.is_empty()).then_some(Value::Array(v))
                }
            };
            if let Some(val) = attached {
                if let Some(obj) = item.as_object_mut() {
                    let exp = obj.entry("expand").or_insert_with(|| json!({}));
                    if let Some(e) = exp.as_object_mut() {
                        e.insert(head.to_string(), val);
                    }
                }
            }
        }
    }
}

// ─── @collection.* join resolution (rules engine) ────────────────────────────

/// Build one engine-filter term for a `@collection.X.field <op> value` ref.
fn collection_term(
    field: &str,
    op: super::predicate::Cmp,
    value: Value,
) -> data_plane_core::Filter {
    use super::predicate::Cmp;
    use data_plane_core::{CmpOp, Filter};
    match op {
        Cmp::Eq if value.is_null() => Filter::IsNull {
            field: field.into(),
            negate: false,
        },
        Cmp::Ne if value.is_null() => Filter::IsNull {
            field: field.into(),
            negate: true,
        },
        Cmp::Eq => Filter::Cmp {
            field: field.into(),
            op: CmpOp::Eq,
            value,
        },
        Cmp::Ne => Filter::Cmp {
            field: field.into(),
            op: CmpOp::Ne,
            value,
        },
        Cmp::Gt => Filter::Cmp {
            field: field.into(),
            op: CmpOp::Gt,
            value,
        },
        Cmp::Gte => Filter::Cmp {
            field: field.into(),
            op: CmpOp::Gte,
            value,
        },
        Cmp::Lt => Filter::Cmp {
            field: field.into(),
            op: CmpOp::Lt,
            value,
        },
        Cmp::Lte => Filter::Cmp {
            field: field.into(),
            op: CmpOp::Lte,
            value,
        },
        Cmp::Like => {
            let raw = value
                .as_str()
                .map(String::from)
                .unwrap_or_else(|| value.to_string());
            let pat = if raw.contains('%') {
                raw
            } else {
                format!("%{raw}%")
            };
            Filter::Like {
                field: field.into(),
                pattern: Value::String(pat),
                ci: true,
            }
        }
        Cmp::NLike => {
            let raw = value
                .as_str()
                .map(String::from)
                .unwrap_or_else(|| value.to_string());
            let pat = if raw.contains('%') {
                raw
            } else {
                format!("%{raw}%")
            };
            Filter::Not(Box::new(Filter::Like {
                field: field.into(),
                pattern: Value::String(pat),
                ci: true,
            }))
        }
    }
}

/// Collect `@collection.X.field` comparison terms, grouped by collection X,
/// resolving the OTHER operand against the outer record. (Same-name refs join
/// one row — PB semantics — so all of X's terms AND together for the EXISTS.)
fn collect_collection_terms(
    expr: &super::predicate::PbExpr,
    outer: &Value,
    groups: &mut HashMap<String, Vec<(String, data_plane_core::Filter)>>,
) {
    use super::predicate::{Operand, PbExpr};
    match expr {
        PbExpr::And(parts) | PbExpr::Or(parts) => {
            for p in parts {
                collect_collection_terms(p, outer, groups);
            }
        }
        PbExpr::Cmp {
            left, op, right, ..
        } => {
            if let Operand::Collection {
                collection,
                alias,
                field,
            } = left
            {
                let val = super::predicate::operand_literal(right, outer);
                let key = match alias {
                    Some(a) => format!("{collection}:{a}"),
                    None => collection.clone(),
                };
                groups
                    .entry(key)
                    .or_default()
                    .push((collection.clone(), collection_term(field, *op, val)));
            }
        }
        PbExpr::Const(_) => {}
    }
}

/// Replace each `@collection.X.*` comparison with the EXISTS result for X.
fn substitute_collection_refs(
    expr: &super::predicate::PbExpr,
    exists: &HashMap<String, bool>,
) -> super::predicate::PbExpr {
    use super::predicate::{Operand, PbExpr};
    match expr {
        PbExpr::And(parts) => PbExpr::And(
            parts
                .iter()
                .map(|p| substitute_collection_refs(p, exists))
                .collect(),
        ),
        PbExpr::Or(parts) => PbExpr::Or(
            parts
                .iter()
                .map(|p| substitute_collection_refs(p, exists))
                .collect(),
        ),
        PbExpr::Cmp { left, .. } => {
            if let Operand::Collection {
                collection, alias, ..
            } = left
            {
                let key = match alias {
                    Some(a) => format!("{collection}:{a}"),
                    None => collection.clone(),
                };
                PbExpr::Const(*exists.get(&key).unwrap_or(&false))
            } else {
                expr.clone()
            }
        }
        PbExpr::Const(b) => PbExpr::Const(*b),
    }
}

/// Resolve `@collection.*` joins (async EXISTS sub-queries) then return the
/// predicate with those terms folded to constants for one outer record.
async fn resolve_collection_refs(
    state: &AppState,
    expr: &super::predicate::PbExpr,
    outer: &Value,
) -> super::predicate::PbExpr {
    let mut groups: HashMap<String, Vec<(String, data_plane_core::Filter)>> = HashMap::new();
    collect_collection_terms(expr, outer, &mut groups);
    let mut exists: HashMap<String, bool> = HashMap::new();
    for (key, terms) in groups {
        let coll = terms.first().map(|(c, _)| c.clone()).unwrap_or_default();
        let filters: Vec<data_plane_core::Filter> = terms.into_iter().map(|(_, f)| f).collect();
        let sub = if filters.len() == 1 {
            filters.into_iter().next().unwrap()
        } else {
            data_plane_core::Filter::And(filters)
        };
        let mut op = base_op(DataOperationKind::List, &coll);
        op.limit = Some(1);
        op.filter = Some(filter_to_wire(&sub));
        let found = matches!(exec(state, op).await, Ok(r) if !r.rows.is_empty());
        exists.insert(key, found);
    }
    substitute_collection_refs(expr, &exists)
}

/// Evaluate an access predicate against one record, resolving any
/// `@collection.*` joins first (async). Use everywhere a rule is checked.
pub(crate) async fn eval_access(
    state: &AppState,
    expr: &super::predicate::PbExpr,
    record: &Value,
) -> bool {
    if expr.has_collection_refs() {
        resolve_collection_refs(state, expr, record)
            .await
            .eval(record)
    } else {
        expr.eval(record)
    }
}

// ─── batch bridge (used by pb::batch) ───────────────────────────────────────

/// One planned batch sub-request: the lowered native op + what to re-fetch.
pub(crate) struct BatchPlan {
    pub op: DataOperation,
    pub collection: String,
    pub record_id: String,
}

/// Parse a PB batch sub-request (`method` + `/api/collections/{c}/records
/// [/{id}]` + body) into a ready native operation, enforcing the same rules
/// and lowering as the live handlers.
pub(crate) fn record_for_batch(
    pb: &super::PbState,
    _state: &AppState,
    _headers: &header::HeaderMap,
    superuser: bool,
    method: &str,
    url: &str,
    body: &Value,
) -> Result<BatchPlan, String> {
    let path = url.split('?').next().unwrap_or(url);
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    // api / collections / {c} / records [ / {id} ]
    if parts.len() < 4 || parts[0] != "api" || parts[1] != "collections" || parts[3] != "records" {
        return Err(format!("unsupported batch url '{url}'"));
    }
    let cname = parts[2];
    let rid = parts.get(4).map(|s| s.to_string());
    let Some(col) = pb.col_get(cname) else {
        return Err(format!("collection '{cname}' not found"));
    };
    let kinds = field_kinds(&col);
    // Batch v1 honors public/locked; expression rules in batch arrive with
    // the Phase L hardening pass (documented limitation, fails CLOSED).
    let pass = |raw: &Option<String>| match rule_of(raw.as_ref()) {
        Rule::Public => true,
        _ => superuser,
    };
    let now = pb_now();
    match (method.to_ascii_uppercase().as_str(), rid) {
        ("POST", None) => {
            if !pass(&col.create_rule) {
                return Err("not allowed to create here".into());
            }
            let mut data = lower_body(&kinds, body)?;
            let id = body
                .get("id")
                .and_then(|v| v.as_str())
                .filter(|s| s.len() == 15)
                .map(String::from)
                .unwrap_or_else(super::pb_id);
            data.insert("id".into(), json!(id));
            for (name, on_create, _) in autodates(&col) {
                if on_create {
                    data.insert(name, json!(now));
                }
            }
            let mut op = base_op(DataOperationKind::Insert, &col.name);
            op.data = Some(Value::Object(data));
            Ok(BatchPlan {
                op,
                collection: col.name.clone(),
                record_id: id,
            })
        }
        ("PATCH", Some(id)) => {
            if !pass(&col.update_rule) {
                return Err("not allowed to update here".into());
            }
            let mut data = lower_body(&kinds, body)?;
            for (name, _, on_update) in autodates(&col) {
                if on_update {
                    data.insert(name, json!(now.clone()));
                }
            }
            if data.is_empty() {
                return Err("empty update body".into());
            }
            let mut op = base_op(DataOperationKind::Update, &col.name);
            op.data = Some(Value::Object(data));
            op.filter = Some(json!({ "id": id }));
            Ok(BatchPlan {
                op,
                collection: col.name.clone(),
                record_id: id,
            })
        }
        ("DELETE", Some(id)) => {
            if !pass(&col.delete_rule) {
                return Err("not allowed to delete here".into());
            }
            let mut op = base_op(DataOperationKind::Delete, &col.name);
            op.filter = Some(json!({ "id": id }));
            Ok(BatchPlan {
                op,
                collection: col.name.clone(),
                record_id: id,
            })
        }
        (m, r) => Err(format!("unsupported batch op {m} (id: {r:?})")),
    }
}

/// Shaped record by collection NAME + id (post-commit re-fetch for batch).
pub(crate) async fn fetch_shaped(
    state: &AppState,
    collection: &str,
    id: &str,
) -> Result<Option<Value>, axum::response::Response> {
    let pb = pb_of(state)?;
    let Some(col) = pb.col_get(collection) else {
        return Ok(None);
    };
    let kinds = field_kinds(&col);
    fetch_by_id(state, &col, &kinds, id).await
}

/// Fan a record event to PB realtime subscribers. `public` mirrors the
/// collection's view rule at this phase.
fn publish_event(state: &AppState, col: &Collection, action: &str, record: &Value) {
    let Ok(pb) = pb_of(state) else { return };
    let rid = record
        .get("id")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let public = matches!(rule_of(col.view_rule.as_ref()), Rule::Public);
    pb.realtime.publish(
        &[col.name.as_str(), col.id.as_str()],
        &rid,
        action,
        record,
        public,
    );
}

// ─── request-body extraction (JSON or multipart) ─────────────────────────────

/// Buffered upload: (file-field name, original filename, bytes).
type PendingFiles = Vec<(String, String, Vec<u8>)>;

/// Read a record payload from either JSON or multipart/form-data (the shape
/// the official SDK sends when a body contains File/Blob values). Multipart
/// text fields are coerced by their declared field kind (number/bool/json);
/// repeated keys accumulate (multi-select). File parts are buffered and
/// persisted by the caller once the record id is settled.
async fn extract_body(
    kinds: &HashMap<String, FieldKind>,
    headers: &header::HeaderMap,
    request: axum::extract::Request,
    state: &AppState,
) -> Result<(Value, PendingFiles), axum::response::Response> {
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string();
    if content_type.starts_with("multipart/form-data") {
        use axum::extract::FromRequest;
        let mut multipart = axum::extract::Multipart::from_request(request, state)
            .await
            .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "malformed multipart body"))?;
        let mut map = JsonMap::new();
        let mut files: PendingFiles = Vec::new();
        let mut total: usize = 0;
        while let Ok(Some(field)) = multipart.next_field().await {
            let name = field.name().unwrap_or_default().to_string();
            if name == "@jsonPayload" {
                if let Ok(text) = field.text().await {
                    if let Ok(Value::Object(extra)) = serde_json::from_str::<Value>(&text) {
                        for (k, v) in extra {
                            map.insert(k, v);
                        }
                    }
                }
                continue;
            }
            let is_file = field.file_name().is_some();
            if is_file {
                let original = field.file_name().unwrap_or("file").to_string();
                let bytes = field
                    .bytes()
                    .await
                    .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "unreadable file part"))?;
                total += bytes.len();
                if total > 64 * 1024 * 1024 {
                    return Err(pb_err(StatusCode::PAYLOAD_TOO_LARGE, "upload too large"));
                }
                files.push((name, original, bytes.to_vec()));
                continue;
            }
            let text = field.text().await.unwrap_or_default();
            let coerced = match kinds.get(name.as_str()) {
                Some(FieldKind::Number) => text
                    .parse::<f64>()
                    .ok()
                    .and_then(serde_json::Number::from_f64)
                    .map(Value::Number)
                    .unwrap_or(Value::Null),
                Some(FieldKind::Bool) => Value::Bool(matches!(text.as_str(), "true" | "1" | "on")),
                Some(FieldKind::Json) => serde_json::from_str(&text).unwrap_or(Value::String(text)),
                _ => Value::String(text),
            };
            match map.get_mut(&name) {
                Some(Value::Array(arr)) => arr.push(coerced),
                Some(prev) => {
                    let first = prev.clone();
                    map.insert(name, Value::Array(vec![first, coerced]));
                }
                None => {
                    map.insert(name, coerced);
                }
            }
        }
        Ok((Value::Object(map), files))
    } else {
        let bytes = axum::body::to_bytes(request.into_body(), 16 * 1024 * 1024)
            .await
            .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "unreadable body"))?;
        let v = if bytes.is_empty() {
            json!({})
        } else {
            serde_json::from_slice(&bytes)
                .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "invalid JSON body"))?
        };
        Ok((v, Vec::new()))
    }
}

/// Write buffered uploads under `{storage}/{col id}/{record id}/` and fold
/// the stored names into `data` (single file field = string, multi = array).
async fn persist_files(
    pb: &super::PbState,
    kinds: &HashMap<String, FieldKind>,
    col_id: &str,
    record_id: &str,
    files: PendingFiles,
    data: &mut JsonMap<String, Value>,
) -> Result<(), axum::response::Response> {
    if files.is_empty() {
        return Ok(());
    }
    #[cfg(feature = "s3")]
    let s3 = super::files::s3_target(&pb.settings_cached());
    let dir = pb.storage_root.join(col_id).join(record_id);
    #[cfg(feature = "s3")]
    let use_s3 = s3.is_some();
    #[cfg(not(feature = "s3"))]
    let use_s3 = false;
    if !use_s3 {
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|_| pb_err(StatusCode::INTERNAL_SERVER_ERROR, "storage unavailable"))?;
    }
    for (field, original, bytes) in files {
        if !matches!(
            kinds.get(field.as_str()),
            Some(FieldKind::Single | FieldKind::Multi)
        ) {
            continue; // not a declared file-capable field — ignored like unknown keys
        }
        let stored = super::files::stored_name(&original);
        #[cfg(feature = "s3")]
        if let Some((bucket, creds)) = s3.as_ref() {
            super::files::s3_put(
                bucket,
                creds,
                &format!("{col_id}/{record_id}/{stored}"),
                bytes.clone(),
            )
            .await
            .map_err(|e| pb_err(StatusCode::INTERNAL_SERVER_ERROR, &e))?;
        }
        if !use_s3 {
            tokio::fs::write(dir.join(&stored), &bytes)
                .await
                .map_err(|_| {
                    pb_err(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "could not persist the file",
                    )
                })?;
        }
        match kinds.get(field.as_str()) {
            Some(FieldKind::Multi) => match data.get_mut(&field) {
                Some(Value::String(prev)) if prev.starts_with('[') => {
                    let mut arr: Vec<Value> = serde_json::from_str(prev).unwrap_or_default();
                    arr.push(json!(stored));
                    data.insert(field, Value::String(Value::Array(arr).to_string()));
                }
                _ => {
                    data.insert(field, Value::String(json!([stored]).to_string()));
                }
            },
            _ => {
                data.insert(field, Value::String(stored));
            }
        }
    }
    Ok(())
}

// ─── handlers ────────────────────────────────────────────────────────────────

fn load_collection(
    state: &AppState,
    name: &str,
) -> Result<(Collection, HashMap<String, FieldKind>), axum::response::Response> {
    let pb = pb_of(state)?;
    let Some(col) = pb.col_get(name) else {
        return Err(pb_err(StatusCode::NOT_FOUND, "collection not found"));
    };
    let kinds = field_kinds(&col);
    Ok((col, kinds))
}

/// GET /api/collections/{c}/records — PB list envelope.
async fn list(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(cname): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (_auth, ctx) = caller(&state, &headers).await;
    let ctx = ctx.with_query(&q);
    let page: u32 = q
        .get("page")
        .and_then(|v| v.parse().ok())
        .unwrap_or(1)
        .max(1);
    let per_page: u32 = q
        .get("perPage")
        .and_then(|v| v.parse().ok())
        .unwrap_or(30)
        .clamp(1, 1000);
    let skip_total = matches!(q.get("skipTotal").map(String::as_str), Some("1" | "true"));

    // Build the combined predicate (user filter AND list rule). Both can use
    // advanced constructs; if either needs in-memory evaluation we fetch a
    // capped candidate set (narrowed by the SQL-expressible conjuncts), filter
    // in Rust, and paginate in Rust — outcome-identical to PB.
    let filter_expr = match q.get("filter").filter(|f| !f.trim().is_empty()) {
        Some(raw) => match super::predicate::parse(raw, &|_| None) {
            Ok(e) => e,
            Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
        },
        None => super::predicate::PbExpr::And(vec![]),
    };
    let combined = match super::rules::rule_pred(col.list_rule.as_ref(), &ctx) {
        super::rules::RulePred::Deny => {
            return pb_err(
                StatusCode::FORBIDDEN,
                "Only superusers can perform this action.",
            );
        }
        super::rules::RulePred::Open => filter_expr,
        super::rules::RulePred::Pred(rp) => super::predicate::PbExpr::And(vec![filter_expr, rp]),
    };

    let mut op = base_op(DataOperationKind::List, &col.name);
    if let Some(raw) = q.get("sort") {
        match parse_sort(raw, &kinds, col.kind == "view") {
            // ponytail: grobase's engine sort is a BTreeMap (no declaration
            // order), so multi-key PB sorts like `?sort=-created,name` collapse
            // to alphabetical key order. Single-key sorts (the common SDK case)
            // are exact. Upgrade path: add an ordered `sort_order: Vec<(_,_)>`
            // to core DataOperation + the sqlite build_order_by_ordered branch
            // (see main's binocle-one) when multi-key PB parity is required.
            Ok(s) if !s.is_empty() => {
                op.sort = Some(s.into_iter().collect::<std::collections::BTreeMap<_, _>>());
            }
            Ok(_) => {}
            Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
        }
    }

    // memory flag + SQL filter
    let memory = combined.needs_memory();
    let sql_filter = if memory {
        combined.sql_prefilter().map(|f| filter_to_wire(&f))
    } else {
        match combined.to_engine_filter().map(|f| (f.fold(), f)) {
            Some((data_plane_core::Folded::AlwaysFalse, _)) => {
                return (
                    StatusCode::OK,
                    Json(json!({ "page": page, "perPage": per_page, "totalItems": 0,
                                  "totalPages": 0, "items": [] })),
                )
                    .into_response();
            }
            Some((data_plane_core::Folded::AlwaysTrue, _)) => None,
            Some((_, f)) => Some(filter_to_wire(&f)),
            None => None,
        }
    };
    op.filter = sql_filter.clone();
    if memory {
        // fetch a capped candidate window (sort honored, no LIMIT/OFFSET)
        op.limit = Some(5000);
    } else {
        op.limit = Some(per_page);
        op.offset = Some((page - 1) * per_page);
    }
    let filter_for_count = op.filter.clone();
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    let su = ctx.superuser;
    let self_id = ctx
        .auth
        .as_ref()
        .and_then(|a| a.get("id"))
        .and_then(Value::as_str)
        .map(String::from);
    let items: Vec<Value> = result
        .rows
        .iter()
        .map(|r| {
            let mut rec = if col.kind == "view" {
                // view columns come from the SELECT — pass rows through raw
                let mut row = r.clone();
                if let Some(o) = row.as_object_mut() {
                    o.insert("collectionId".into(), json!(col.id));
                    o.insert("collectionName".into(), json!(col.name));
                }
                row
            } else {
                shape_record(&col, &kinds, r)
            };
            if col.kind == "auth" {
                let is_self = self_id.as_deref() == rec.get("id").and_then(Value::as_str);
                super::auth::scrub_auth_record(&mut rec, su || is_self);
            }
            rec
        })
        .collect();
    let mut items = items;

    // in-memory predicate: keep matching rows, then paginate in Rust
    let mem_total: Option<i64> = if memory {
        // async filter (resolves @collection refs per row)
        let mut kept: Vec<Value> = Vec::new();
        for rec in items.into_iter() {
            if eval_access(&state, &combined, &rec).await {
                kept.push(rec);
            }
        }
        let total = kept.len() as i64;
        let start = ((page - 1) * per_page) as usize;
        items = kept
            .into_iter()
            .skip(start)
            .take(per_page as usize)
            .collect();
        Some(total)
    } else {
        None
    };

    if let Some(exp) = q.get("expand").filter(|e| !e.trim().is_empty()) {
        apply_expand(&state, &col, &mut items, exp, &ctx, 1).await;
    }

    let (total_items, total_pages) = if skip_total {
        (-1i64, -1i64)
    } else if let Some(total) = mem_total {
        (total, (total + per_page as i64 - 1) / per_page as i64)
    } else {
        let mut count_op = base_op(DataOperationKind::Aggregate, &col.name);
        count_op.filter = filter_for_count;
        count_op.aggregate = Some(data_plane_core::AggregateSpec {
            group_by: vec![],
            aggregates: vec![data_plane_core::Aggregate {
                func: data_plane_core::AggFunc::Count,
                field: None,
                distinct: false,
                alias: "n".to_string(),
            }],
        });
        match exec(&state, count_op).await {
            Ok(r) => {
                let n = r
                    .rows
                    .first()
                    .and_then(|row| row.get("n"))
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                (n, (n + per_page as i64 - 1) / per_page as i64)
            }
            Err(r) => return r,
        }
    };

    (
        StatusCode::OK,
        Json(json!({
            "page": page,
            "perPage": per_page,
            "totalItems": total_items,
            "totalPages": total_pages,
            "items": items,
        })),
    )
        .into_response()
}

async fn fetch_by_id(
    state: &AppState,
    col: &Collection,
    kinds: &HashMap<String, FieldKind>,
    id: &str,
) -> Result<Option<Value>, axum::response::Response> {
    let mut op = base_op(DataOperationKind::Get, &col.name);
    op.filter = Some(json!({ "id": id }));
    let result = exec(state, op).await?;
    Ok(result.rows.first().map(|r| shape_record(col, kinds, r)))
}

/// GET /api/collections/{c}/records/{id}
async fn view(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
    Query(q): Query<HashMap<String, String>>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (_auth, ctx) = caller(&state, &headers).await;
    let ctx = ctx.with_query(&q);
    let pred = super::rules::rule_pred(col.view_rule.as_ref(), &ctx);
    if matches!(pred, super::rules::RulePred::Deny) {
        return pb_err(
            StatusCode::NOT_FOUND,
            "The requested resource wasn't found.",
        );
    }
    let mut op = base_op(DataOperationKind::Get, &col.name);
    op.filter = Some(json!({ "id": rid }));
    match exec(&state, op)
        .await
        .map(|r| r.rows.first().map(|row| shape_record(&col, &kinds, row)))
    {
        Ok(Some(mut rec)) => {
            // the view rule gates the record in memory (covers advanced rules)
            if let super::rules::RulePred::Pred(e) = &pred {
                if !eval_access(&state, e, &rec).await {
                    return pb_err(
                        StatusCode::NOT_FOUND,
                        "The requested resource wasn't found.",
                    );
                }
            }
            if let Some(exp) = q.get("expand").filter(|e| !e.trim().is_empty()) {
                let mut one_item = vec![rec];
                apply_expand(&state, &col, &mut one_item, exp, &ctx, 1).await;
                rec = one_item.pop().unwrap_or(Value::Null);
            }
            if col.kind == "auth" {
                let su = ctx.superuser;
                let is_self = ctx
                    .auth
                    .as_ref()
                    .and_then(|a| a.get("id"))
                    .and_then(Value::as_str)
                    == rec.get("id").and_then(Value::as_str);
                super::auth::scrub_auth_record(&mut rec, su || is_self);
            }
            (StatusCode::OK, Json(rec)).into_response()
        }
        Ok(None) => pb_err(
            StatusCode::NOT_FOUND,
            "The requested resource wasn't found.",
        ),
        Err(r) => r,
    }
}

/// POST /api/collections/{c}/records
async fn create(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(cname): Path<String>,
    request: axum::extract::Request,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    if col.kind == "view" {
        return pb_err(
            StatusCode::BAD_REQUEST,
            "unable to create a view collection record",
        );
    }
    let (_auth, ctx) = caller(&state, &headers).await;
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let (body, pending) = match extract_body(&kinds, &headers, request, &state).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut data = match lower_body(&kinds, &body) {
        Ok(d) => d,
        Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
    };
    // Auth collections: validate + hash the password server-side.
    if col.kind == "auth" {
        let password = body
            .get("password")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let confirm = body
            .get("passwordConfirm")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        if password.len() < 8 || password != confirm {
            return pb_err(StatusCode::BAD_REQUEST, "invalid or unconfirmed password");
        }
        let email = body
            .get("email")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_lowercase();
        if email.is_empty() || !email.contains('@') {
            return pb_err(StatusCode::BAD_REQUEST, "invalid email");
        }
        let pw = password.to_string();
        let hash = match crate::one::kdf_blocking(move || crate::one::hash_password(&pw)).await {
            Some(Ok(h)) => h,
            _ => return pb_err(StatusCode::INTERNAL_SERVER_ERROR, "password hashing failed"),
        };
        data.insert("email".into(), json!(email));
        data.insert("password".into(), json!(hash));
    }
    let id = body
        .get("id")
        .and_then(|v| v.as_str())
        .filter(|s| {
            s.len() == 15
                && s.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        })
        .map(String::from)
        .unwrap_or_else(pb_id);
    let now = pb_now();
    data.insert("id".into(), json!(id));
    for (name, on_create, _) in autodates(&col) {
        if on_create {
            data.insert(name, json!(now));
        }
    }

    // JS hooks: onRecordCreateRequest may mutate the record or reject.
    #[cfg(feature = "hooks")]
    if let Some(hooks) = state.hooks.clone() {
        if hooks.active_for(super::hooks::ACT_CREATE) {
            match hooks
                .fire_record("create", &col.name, &Value::Object(data.clone()))
                .await
            {
                Ok(Some(Value::Object(mutated))) => data = mutated,
                Ok(_) => {}
                Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
            }
        }
    }
    // createRule is checked against the submitted body + the would-be record
    let create_rule = super::rules::rule_pred(
        col.create_rule.as_ref(),
        &ctx.clone().with_body(body.clone()),
    );
    if matches!(create_rule, super::rules::RulePred::Deny) {
        return pb_err(
            StatusCode::FORBIDDEN,
            "Only superusers can perform this action.",
        );
    }
    if let super::rules::RulePred::Pred(e) = &create_rule {
        if !eval_access(&state, e, &Value::Object(data.clone())).await {
            return pb_err(StatusCode::BAD_REQUEST, "Failed to create record.");
        }
    }
    if let Err(r) = persist_files(&pb, &kinds, &col.id, &id, pending, &mut data).await {
        return r;
    }
    let mut op = base_op(DataOperationKind::Insert, &col.name);
    op.data = Some(Value::Object(data));
    if let Err(r) = exec(&state, op).await {
        return r;
    }
    match fetch_by_id(&state, &col, &kinds, &id).await {
        Ok(Some(mut rec)) => {
            publish_event(&state, &col, "create", &rec);
            if col.kind == "auth" {
                super::auth::scrub_auth_record(&mut rec, true);
            }
            (StatusCode::OK, Json(rec)).into_response()
        }
        Ok(None) => pb_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "record vanished after insert",
        ),
        Err(r) => r,
    }
}

/// PATCH /api/collections/{c}/records/{id}
async fn update(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
    request: axum::extract::Request,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    if col.kind == "view" {
        return pb_err(
            StatusCode::BAD_REQUEST,
            "unable to update a view collection record",
        );
    }
    let (_auth, ctx) = caller(&state, &headers).await;
    if matches!(
        super::rules::rule_pred(col.update_rule.as_ref(), &ctx),
        super::rules::RulePred::Deny
    ) {
        return pb_err(
            StatusCode::FORBIDDEN,
            "Only superusers can perform this action.",
        );
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let (body, pending) = match extract_body(&kinds, &headers, request, &state).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut data = match lower_body(&kinds, &body) {
        Ok(d) => d,
        Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
    };
    // The update rule is checked against the EXISTING record + submitted body.
    if let super::rules::RulePred::Pred(e) = super::rules::rule_pred(
        col.update_rule.as_ref(),
        &ctx.clone().with_body(body.clone()),
    ) {
        let allowed = match fetch_by_id(&state, &col, &kinds, &rid).await {
            Ok(Some(existing)) => eval_access(&state, &e, &existing).await,
            _ => false,
        };
        if !allowed {
            return pb_err(
                StatusCode::NOT_FOUND,
                "The requested resource wasn't found.",
            );
        }
    }
    if let Err(r) = persist_files(&pb, &kinds, &col.id, &rid, pending, &mut data).await {
        return r;
    }
    let now = pb_now();
    for (name, _, on_update) in autodates(&col) {
        if on_update {
            data.insert(name, json!(now));
        }
    }
    if data.is_empty() {
        // Nothing settable and no autodate to bump — PB answers with the
        // unchanged record rather than erroring.
        return match fetch_by_id(&state, &col, &kinds, &rid).await {
            Ok(Some(rec)) => (StatusCode::OK, Json(rec)).into_response(),
            Ok(None) => pb_err(
                StatusCode::NOT_FOUND,
                "The requested resource wasn't found.",
            ),
            Err(r) => r,
        };
    }
    #[cfg(feature = "hooks")]
    if let Some(hooks) = state.hooks.clone() {
        if hooks.active_for(super::hooks::ACT_UPDATE) {
            match hooks
                .fire_record("update", &col.name, &Value::Object(data.clone()))
                .await
            {
                Ok(Some(Value::Object(mutated))) => data = mutated,
                Ok(_) => {}
                Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
            }
        }
    }
    let mut op = base_op(DataOperationKind::Update, &col.name);
    op.data = Some(Value::Object(data));
    op.filter = Some(json!({ "id": rid }));
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    if result.affected_rows == 0 {
        return pb_err(
            StatusCode::NOT_FOUND,
            "The requested resource wasn't found.",
        );
    }
    match fetch_by_id(&state, &col, &kinds, &rid).await {
        Ok(Some(rec)) => {
            publish_event(&state, &col, "update", &rec);
            (StatusCode::OK, Json(rec)).into_response()
        }
        Ok(None) => pb_err(
            StatusCode::NOT_FOUND,
            "The requested resource wasn't found.",
        ),
        Err(r) => r,
    }
}

/// DELETE /api/collections/{c}/records/{id}
async fn remove(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    if col.kind == "view" {
        return pb_err(
            StatusCode::BAD_REQUEST,
            "unable to delete a view collection record",
        );
    }
    let (_auth, ctx) = caller(&state, &headers).await;
    let delete_rule = super::rules::rule_pred(col.delete_rule.as_ref(), &ctx);
    if matches!(delete_rule, super::rules::RulePred::Deny) {
        return pb_err(
            StatusCode::FORBIDDEN,
            "Only superusers can perform this action.",
        );
    }
    // Pre-image for the realtime event (PB sends the deleted record's last
    // known state) AND the delete-rule gate (checked in memory).
    let pre = fetch_by_id(&state, &col, &kinds, &rid).await.ok().flatten();
    if let super::rules::RulePred::Pred(e) = &delete_rule {
        let allowed = match &pre {
            Some(rec) => eval_access(&state, e, rec).await,
            None => false,
        };
        if !allowed {
            return pb_err(
                StatusCode::NOT_FOUND,
                "The requested resource wasn't found.",
            );
        }
    }
    #[cfg(feature = "hooks")]
    if let Some(hooks) = state.hooks.clone() {
        if hooks.active_for(super::hooks::ACT_DELETE) {
            let payload = pre.clone().unwrap_or_else(|| json!({ "id": rid }));
            if let Err(m) = hooks.fire_record("delete", &col.name, &payload).await {
                return pb_err(StatusCode::BAD_REQUEST, &m);
            }
        }
    }
    let mut op = base_op(DataOperationKind::Delete, &col.name);
    op.filter = Some(json!({ "id": rid }));
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    if result.affected_rows == 0 {
        return pb_err(
            StatusCode::NOT_FOUND,
            "The requested resource wasn't found.",
        );
    }
    if let Some(rec) = pre.as_ref() {
        publish_event(&state, &col, "delete", rec);
    }
    if let Ok(pb) = pb_of(&state) {
        super::files::remove_record_files(&pb, &col.id, &rid).await;
        #[cfg(feature = "s3")]
        if let Some((bucket, creds)) = super::files::s3_target(&pb.settings_cached()) {
            if let Some(rec) = pre.as_ref() {
                for (name, kind) in &kinds {
                    if !matches!(kind, FieldKind::Single | FieldKind::Multi) {
                        continue;
                    }
                    match rec.get(name) {
                        Some(Value::String(stored)) if !stored.is_empty() => {
                            super::files::s3_delete(
                                &bucket,
                                &creds,
                                &format!("{}/{}/{}", col.id, rid, stored),
                            )
                            .await;
                        }
                        Some(Value::Array(items)) => {
                            for it in items {
                                if let Some(stored) = it.as_str() {
                                    super::files::s3_delete(
                                        &bucket,
                                        &creds,
                                        &format!("{}/{}/{}", col.id, rid, stored),
                                    )
                                    .await;
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }
    StatusCode::NO_CONTENT.into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/api/collections/:collection/records",
            get(list).post(create),
        )
        .route(
            "/api/collections/:collection/records/:id",
            get(view).patch(update).delete(remove),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn col_with(fields: Value) -> Collection {
        Collection {
            id: "pbc_x".into(),
            name: "t".into(),
            kind: "base".into(),
            fields,
            options: json!({}),
            list_rule: Some(String::new()),
            view_rule: Some(String::new()),
            create_rule: Some(String::new()),
            update_rule: Some(String::new()),
            delete_rule: Some(String::new()),
            indexes: json!([]),
            created: String::new(),
            updated: String::new(),
        }
    }

    #[test]
    fn shapes_typed_values_and_zero_defaults() {
        let col = col_with(json!([
            {"name": "id", "type": "text", "system": true},
            {"name": "title", "type": "text"},
            {"name": "n", "type": "number"},
            {"name": "ok", "type": "bool"},
            {"name": "meta", "type": "json"},
            {"name": "tags", "type": "select", "maxSelect": 5},
        ]));
        let kinds = field_kinds(&col);
        let row = json!({"id": "abc", "title": null, "n": null, "ok": 1,
                         "meta": "{\"a\":1}", "tags": "[\"x\",\"y\"]"});
        let rec = shape_record(&col, &kinds, &row);
        assert_eq!(rec["title"], json!(""), "NULL text renders as empty string");
        assert_eq!(rec["n"], json!(0), "NULL number renders as 0");
        assert_eq!(rec["ok"], json!(true), "INTEGER 1 renders as true");
        assert_eq!(rec["meta"], json!({"a": 1}), "json TEXT parses");
        assert_eq!(
            rec["tags"],
            json!(["x", "y"]),
            "multi-select parses to array"
        );
        assert_eq!(rec["collectionName"], json!("t"));
    }

    #[test]
    fn lower_body_keeps_declared_fields_and_stringifies_json() {
        let col = col_with(json!([
            {"name": "title", "type": "text"},
            {"name": "meta", "type": "json"},
        ]));
        let kinds = field_kinds(&col);
        let body = json!({"title": "x", "meta": {"a": 1}, "evil": "ignored"});
        let out = lower_body(&kinds, &body).unwrap();
        assert_eq!(out.get("title"), Some(&json!("x")));
        assert_eq!(
            out.get("meta"),
            Some(&json!("{\"a\":1}")),
            "json lowered to TEXT"
        );
        assert!(!out.contains_key("evil"), "unknown keys ignored like PB");
    }

    #[test]
    fn sort_parses_ordered_and_rejects_unknown() {
        let col = col_with(json!([{"name": "b", "type": "text"}, {"name": "a", "type": "text"}]));
        let kinds = field_kinds(&col);
        let s = parse_sort("-b,a,+id", &kinds, false).unwrap();
        assert_eq!(
            s,
            vec![
                ("b".to_string(), "desc".to_string()),
                ("a".to_string(), "asc".to_string()),
                ("id".to_string(), "asc".to_string()),
            ],
            "declaration order preserved — the reason sort_order exists"
        );
        assert!(
            parse_sort("created", &kinds, false).is_err(),
            "created only when declared"
        );
        assert!(parse_sort("nope", &kinds, false).is_err());
    }

    #[test]
    fn autodate_fields_are_server_owned() {
        let col = col_with(json!([
            {"name": "title", "type": "text"},
            {"name": "created", "type": "autodate", "onCreate": true, "onUpdate": false},
            {"name": "updated", "type": "autodate", "onCreate": true, "onUpdate": true},
        ]));
        let kinds = field_kinds(&col);
        let out = lower_body(&kinds, &json!({"title": "x", "created": "spoof"})).unwrap();
        assert!(
            !out.contains_key("created"),
            "client can never set an autodate"
        );
        let ad = autodates(&col);
        assert_eq!(
            ad,
            vec![
                ("created".to_string(), true, false),
                ("updated".to_string(), true, true),
            ]
        );
    }

    #[test]
    fn pb_ids_are_15_lowercase_alnum() {
        for _ in 0..50 {
            let id = super::super::pb_id();
            assert_eq!(id.len(), 15);
            assert!(
                id.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()),
                "{id}"
            );
        }
    }

    #[test]
    fn filter_wire_round_trips_through_engine_grammar() {
        let wire = filter_wire("status = 'active' && n > 3").unwrap().unwrap();
        // must parse under the ENGINE's validating grammar
        assert!(data_plane_core::Filter::parse(&wire).is_ok());
        assert!(filter_wire("").unwrap().is_none());
        assert!(filter_wire("bad ===").is_err());
    }
}
