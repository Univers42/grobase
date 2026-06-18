//! Owner-scoping + parameter binding — the security core shared by every CRUD
//! builder in [`super::query`]. Every read intersects `owner_id = ?`; every
//! write re-stamps `owner_id` from the verified identity. The engine-neutral
//! filter lowering lives in [`crate::sql_scope`]; only the `owner_id` stamping
//! here is MySQL-specific.

use super::convert::json_to_mysql_value;
use super::*;

pub(super) fn owner_of(identity: &RequestIdentity) -> String {
    identity.owner_principal().to_string()
}

/// MySQL binds every value as a positional `?` (param order IS binding order),
/// so the shared filter lowerer pushes through this private sink:
/// `bind` records the value via [`json_to_mysql_value`] and emits `?`;
/// `quote_ident` defers to [`quote_mysql_ident`]. Kept private (never `pub`) so
/// no caller can bypass `bind` and bind a value to the wrong column.
pub(super) struct MysqlSink(pub(super) Vec<MysqlValue>);

impl crate::sql_scope::SqlParamSink for MysqlSink {
    fn bind(&mut self, value: &Value) -> String {
        self.0.push(json_to_mysql_value(value));
        "?".to_string()
    }
    fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
        quote_mysql_ident(name)
    }
}

/// Take the client filter, strip any attempt to override `owner_id`, then —
/// when `scoped` — intersect with the server-trusted owner. The reserved
/// `owner_id` is ALWAYS stripped from client input first (a shared read can't
/// be tricked into forging it either). When `scoped` is true the trusted
/// `owner_id = ?` predicate is appended (the second line of defense against
/// tenant escape — defense in depth alongside per-mount DSN isolation); when
/// `scoped` is false (a NAMED shared catalog table on a per-table-isolation
/// mount) it is NOT appended, so an empty client filter yields no `WHERE` at
/// all. The engine-neutral filter lowering lives in [`crate::sql_scope`]; only
/// the `owner_id` stamping below is MySQL-specific.
pub(super) fn build_owner_filter(
    filter: Option<&Value>,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<(String, Vec<MysqlValue>)> {
    let mut sink = MysqlSink(Vec::new());
    let mut clauses: Vec<String> = Vec::new();

    if let Some(filter_value) = filter {
        // Drop any top-level reserved-column override (the trusted value is added
        // below) before parsing, matching the prior posture. The trusted
        // `owner_id` predicate also supersedes any nested client `owner_id`.
        let cleaned = crate::sql_scope::strip_reserved_top_level(filter_value, &RESERVED_COLUMNS);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = crate::sql_scope::lower_filter(&tree, &mut sink)? {
            // Parenthesize the WHOLE client filter so the trusted `owner_id` AND
            // binds it as one unit. Without this, a top-level `$or` would parse
            // as `(a) OR (b AND owner_id)` — the `a` branch unscoped (cross-owner
            // leak), because SQL `AND` binds tighter than `OR`.
            clauses.push(format!("({sql})"));
        }
    }

    if scoped {
        sink.0
            .push(MysqlValue::Bytes(owner_of(identity).into_bytes()));
        clauses.push("`owner_id` = ?".to_string());
    }

    if clauses.is_empty() {
        return Ok((String::new(), sink.0));
    }
    Ok((format!(" WHERE {}", clauses.join(" AND ")), sink.0))
}

/// Strip reserved columns from client payload, then — when `scoped` — re-inject
/// the trusted `owner_id`. Returns the ordered list of (column, value) pairs and
/// is the shared core of `INSERT` and `UPSERT`. When `scoped` is false (a NAMED
/// shared catalog table) the reserved columns are still stripped, but no trusted
/// `owner_id` is appended, so the row carries no owner stamp.
pub(super) fn build_owned_columns(
    data: Option<&Value>,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut columns: Vec<(String, Value)> = Vec::with_capacity(map.len() + 1);
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        columns.push((col.clone(), val.clone()));
    }
    if scoped {
        columns.push(("owner_id".to_string(), Value::String(owner_of(identity))));
    }
    Ok(columns)
}

/// Same shape as `build_owned_columns` but for UPDATE — drops reserved
/// columns from the SET list without re-injecting (UPDATE doesn't need to
/// re-set `owner_id`; the WHERE clause already scopes the row).
pub(super) fn build_safe_columns(data: Option<&Value>) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut out: Vec<(String, Value)> = Vec::with_capacity(map.len());
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        out.push((col.clone(), val.clone()));
    }
    Ok(out)
}

pub(super) fn require_object<'a>(
    data: Option<&'a Value>,
    what: &str,
) -> DataPlaneResult<&'a JsonMap<String, Value>> {
    match data {
        Some(Value::Object(map)) => Ok(map),
        Some(other) => Err(DataPlaneError::InvalidRequest {
            message: format!("{what} must be a JSON object, got {other:?}"),
        }),
        None => Err(DataPlaneError::InvalidRequest {
            message: format!("{what} is required"),
        }),
    }
}

/// Rendered SQL fragments + ordered bind parameters + the echo payload that
/// the adapter returns to the caller. Avoids a 4-tuple return that clippy
/// flags as `type_complexity`.
pub(super) struct InsertSqlFragments {
    pub(super) columns_sql: String,
    pub(super) placeholders: String,
    pub(super) params: Vec<MysqlValue>,
    pub(super) echo: JsonMap<String, Value>,
}

pub(super) fn render_insert_columns(
    columns: &[(String, Value)],
) -> DataPlaneResult<InsertSqlFragments> {
    let mut col_sql: Vec<String> = Vec::with_capacity(columns.len());
    let mut placeholders: Vec<&'static str> = Vec::with_capacity(columns.len());
    let mut params: Vec<MysqlValue> = Vec::with_capacity(columns.len());
    let mut echo = JsonMap::with_capacity(columns.len());
    for (col, val) in columns {
        let quoted = quote_mysql_ident(col)?;
        col_sql.push(quoted);
        placeholders.push("?");
        params.push(json_to_mysql_value(val));
        echo.insert(col.clone(), val.clone());
    }
    Ok(InsertSqlFragments {
        columns_sql: col_sql.join(", "),
        placeholders: placeholders.join(", "),
        params,
        echo,
    })
}

pub(super) fn build_order_by(sort: Option<&BTreeMap<String, String>>) -> DataPlaneResult<String> {
    let Some(map) = sort else {
        return Ok(String::new());
    };
    if map.is_empty() {
        return Ok(String::new());
    }
    let mut parts: Vec<String> = Vec::with_capacity(map.len());
    for (col, dir) in map {
        let quoted = quote_mysql_ident(col)?;
        let dir_sql = if dir.eq_ignore_ascii_case("desc") {
            "DESC"
        } else {
            "ASC"
        };
        parts.push(format!("{quoted} {dir_sql}"));
    }
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}
