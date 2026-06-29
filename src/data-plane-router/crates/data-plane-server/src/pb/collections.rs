//! PB collections registry + the `/api/collections` management surface.
//!
//! A collection is PB's table-with-schema: name, type (base/auth/view),
//! fields (the 13 PB field types), API rules, indexes. The registry stores
//! the PB-shaped JSON verbatim (echoed back byte-faithfully to the SDK) in
//! pb_meta.db; creating one lowers the fields to a real SQLite table on the
//! `pb` mount. v1 honesty: PATCH supports rule changes and ADDING fields
//! (ALTER TABLE ADD COLUMN); removing/renaming fields arrives with Phase L's
//! migration engine — until then those PATCHes are refused loudly, never
//! silently dropped.

use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};

use super::{pb_auth, pb_err, pb_id, pb_now, pb_of, PbAuth};
use crate::routes::AppState;

/// Collection/field names become SQL identifiers — same rule PB enforces.
fn valid_ident(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.chars().enumerate().all(|(i, c)| {
            c == '_'
                || c.is_ascii_alphanumeric() && (i > 0 || !c.is_ascii_digit())
                || (i > 0 && c.is_ascii_digit())
        })
        && !name.starts_with(|c: char| c.is_ascii_digit())
}

/// One PB field type → its SQLite column type. Single source of truth for
/// the DDL lowering; the PB-shaped JSON keeps the original type string.
fn column_type(pb_type: &str) -> Option<&'static str> {
    Some(match pb_type {
        "text" | "email" | "url" | "editor" | "date" | "autodate" => "TEXT",
        "select" | "file" | "relation" => "TEXT", // single value; multi = JSON text
        "json" | "geoPoint" => "TEXT",
        "number" => "REAL",
        "bool" => "INTEGER",
        "password" => "TEXT",
        _ => return None,
    })
}

#[derive(Clone)]
pub(crate) struct Collection {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub fields: Value,
    /// Auth-config blob (otp/mfa/passwordAuth/oauth2...), spread at the top
    /// level of the PB-shaped JSON like PB does.
    pub options: Value,
    pub list_rule: Option<String>,
    pub view_rule: Option<String>,
    pub create_rule: Option<String>,
    pub update_rule: Option<String>,
    pub delete_rule: Option<String>,
    pub indexes: Value,
    pub created: String,
    pub updated: String,
}

impl Collection {
    pub(crate) fn to_json(&self) -> Value {
        let mut base = json!({
            "id": self.id,
            "name": self.name,
            "type": self.kind,
            "system": false,
            "fields": self.fields,
            "indexes": self.indexes,
            "listRule": self.list_rule,
            "viewRule": self.view_rule,
            "createRule": self.create_rule,
            "updateRule": self.update_rule,
            "deleteRule": self.delete_rule,
            "created": self.created,
            "updated": self.updated,
        });
        // PB spreads auth-config keys (otp/mfa/passwordAuth/...) at the top.
        if let (Some(b), Some(o)) = (base.as_object_mut(), self.options.as_object()) {
            for (k, v) in o {
                b.insert(k.clone(), v.clone());
            }
        }
        base
    }

    fn from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        let fields_raw: String = r.get(3)?;
        let indexes_raw: String = r.get(9)?;
        let options_raw: String = r.get(12)?;
        Ok(Self {
            id: r.get(0)?,
            name: r.get(1)?,
            kind: r.get(2)?,
            fields: serde_json::from_str(&fields_raw).unwrap_or(Value::Array(vec![])),
            options: serde_json::from_str(&options_raw).unwrap_or_else(|_| json!({})),
            list_rule: r.get(4)?,
            view_rule: r.get(5)?,
            create_rule: r.get(6)?,
            update_rule: r.get(7)?,
            delete_rule: r.get(8)?,
            indexes: serde_json::from_str(&indexes_raw).unwrap_or(Value::Array(vec![])),
            created: r.get(10)?,
            updated: r.get(11)?,
        })
    }
}

const COL_SELECT: &str = "SELECT id, name, type, fields, listRule, viewRule, createRule, \
     updateRule, deleteRule, indexes, created, updated, options FROM pb_collections";

impl super::PbState {
    /// Automigrate journal — the file-less equivalent of PB's pb_migrations:
    /// every collection change records a full snapshot, so schema history is
    /// inspectable and replayable.
    pub(crate) fn migration_record(&self, kind: &str, c: &Collection) {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = conn.execute(
            "INSERT INTO pb_migrations_history (id, type, collection, snapshot, created)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![pb_id(), kind, c.name, c.to_json().to_string(), pb_now(),],
        );
    }

    pub(crate) fn col_get(&self, id_or_name: &str) -> Option<Collection> {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        conn.query_row(
            &format!("{COL_SELECT} WHERE id = ?1 OR name = ?1"),
            [id_or_name],
            Collection::from_row,
        )
        .ok()
    }

    pub(crate) fn col_list(&self) -> Vec<Collection> {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Ok(mut stmt) = conn.prepare(&format!("{COL_SELECT} ORDER BY created, name")) else {
            return vec![];
        };
        let rows = stmt.query_map([], Collection::from_row);
        rows.map(|it| it.flatten().collect()).unwrap_or_default()
    }

    fn col_insert(&self, c: &Collection) -> Result<(), String> {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        conn.execute(
            "INSERT INTO pb_collections (id, name, type, system, fields, listRule, viewRule,
             createRule, updateRule, deleteRule, indexes, options, created, updated)
             VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?12, ?11, ?11)",
            rusqlite::params![
                c.id,
                c.name,
                c.kind,
                c.fields.to_string(),
                c.list_rule,
                c.view_rule,
                c.create_rule,
                c.update_rule,
                c.delete_rule,
                c.indexes.to_string(),
                c.created,
                c.options.to_string(),
            ],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    fn col_update(&self, c: &Collection) -> Result<(), String> {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        conn.execute(
            "UPDATE pb_collections SET fields = ?2, listRule = ?3, viewRule = ?4,
             createRule = ?5, updateRule = ?6, deleteRule = ?7, indexes = ?8, updated = ?9,
             options = ?10
             WHERE id = ?1",
            rusqlite::params![
                c.id,
                c.fields.to_string(),
                c.list_rule,
                c.view_rule,
                c.create_rule,
                c.update_rule,
                c.delete_rule,
                c.indexes.to_string(),
                pb_now(),
                c.options.to_string(),
            ],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    fn col_delete(&self, id: &str) -> bool {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        conn.execute("DELETE FROM pb_collections WHERE id = ?1", [id])
            .unwrap_or(0)
            > 0
    }
}

// ─── field normalization + DDL ───────────────────────────────────────────────

/// Validate client fields and inject the system ones (id, created, updated)
/// exactly as PB does for a new collection. Returns the normalized fields
/// array plus the (name, sqlite type) pairs for the DDL.
/// (field name, sqlite column type) pairs the DDL lowers.
type ColumnDefs = Vec<(String, &'static str)>;

fn normalize_fields(input: Option<&Value>) -> Result<(Value, ColumnDefs), String> {
    normalize_fields_for(input, false)
}

fn normalize_fields_for(
    input: Option<&Value>,
    is_auth: bool,
) -> Result<(Value, ColumnDefs), String> {
    let mut out: Vec<Value> = Vec::new();
    let mut cols: ColumnDefs = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let empty = vec![];
    let items = input.and_then(|v| v.as_array()).unwrap_or(&empty);
    for item in items {
        let name = item
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let ftype = item
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        if !valid_ident(name) {
            return Err(format!("invalid field name '{name}'"));
        }
        if name == "id"
            || (is_auth && matches!(name, "email" | "password" | "verified" | "emailVisibility"))
        {
            continue; // system fields are injected below
        }
        let Some(col) = column_type(ftype) else {
            return Err(format!("unknown field type '{ftype}'"));
        };
        if !seen.insert(name.to_string()) {
            return Err(format!("duplicate field '{name}'"));
        }
        let mut f = item.clone();
        if f.get("id").is_none() {
            f["id"] = json!(format!("f_{}", pb_id()));
        }
        cols.push((name.to_string(), col));
        out.push(f);
    }
    // PB injects exactly ONE implicit system field via the API: id. created/
    // updated exist only when the client declares autodate fields (the PB
    // dashboard adds them by default — the API, and so this facade, does not).
    let id_field = json!({"id": "f_sys_id0000000", "name": "id", "type": "text", "system": true,
               "required": true, "primaryKey": true, "min": 15, "max": 15,
               "pattern": "^[a-z0-9]+$", "autogeneratePattern": "[a-z0-9]{15}"});
    let mut all = vec![id_field];
    if is_auth {
        // PB auth-collection system fields: identity columns the auth
        // endpoints depend on. `password` is write-only (never serialized).
        all.push(
            json!({"id": "f_sys_email0000", "name": "email", "type": "email",
                        "system": true, "required": true}),
        );
        all.push(
            json!({"id": "f_sys_password0", "name": "password", "type": "password",
                        "system": true, "required": true, "hidden": true}),
        );
        all.push(
            json!({"id": "f_sys_verified0", "name": "verified", "type": "bool",
                        "system": true}),
        );
        all.push(
            json!({"id": "f_sys_emailvis0", "name": "emailVisibility", "type": "bool",
                        "system": true}),
        );
        for (name, ty) in [
            ("email", "TEXT"),
            ("password", "TEXT"),
            ("verified", "INTEGER"),
            ("emailVisibility", "INTEGER"),
        ] {
            if !cols.iter().any(|(n, _)| n == name) {
                cols.push((name.to_string(), ty));
            }
        }
    }
    all.extend(out);
    Ok((Value::Array(all), cols))
}

fn create_table_sql(name: &str, cols: &[(String, &'static str)]) -> String {
    let mut parts = vec!["\"id\" TEXT PRIMARY KEY".to_string()];
    for (col, ty) in cols {
        parts.push(format!("\"{col}\" {ty}"));
    }
    format!(
        "CREATE TABLE IF NOT EXISTS \"{name}\" ({})",
        parts.join(", ")
    )
}

/// Run facade-side DDL through the engine's writer thread (raw, expect_rows
/// false) so the data file has exactly one writer.
async fn exec_ddl(state: &AppState, sql: String) -> Result<(), axum::response::Response> {
    let Some(nano) = state.nano.as_ref() else {
        return Err(pb_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "engine unavailable",
        ));
    };
    let _ = nano; // mount resolution happens inside exec via the same helper
    let op = data_plane_core::RawStatement {
        statement: sql,
        params: vec![],
        expect_rows: false,
    };
    super::exec_raw(state, op).await.map(|_| ())
}

// ─── handlers ────────────────────────────────────────────────────────────────

fn require_superuser(
    state: &AppState,
    headers: &header::HeaderMap,
) -> Result<(), axum::response::Response> {
    match pb_auth(state, headers) {
        PbAuth::Superuser => Ok(()),
        _ => Err(pb_err(
            StatusCode::FORBIDDEN,
            "Only superusers can perform this action.",
        )),
    }
}

/// POST /api/collections — create (superuser).
async fn create(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<Value>,
) -> axum::response::Response {
    if let Err(r) = require_superuser(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let name = req
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let kind = req
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("base")
        .to_string();
    if !valid_ident(&name) || name.starts_with('_') {
        return pb_err(StatusCode::BAD_REQUEST, "invalid collection name");
    }
    if kind == "view" {
        // SELECT-backed read-only collection: no table, the query IS the data.
        let Some(q) = req.get("viewQuery").and_then(|v| v.as_str()).map(str::trim) else {
            return pb_err(
                StatusCode::BAD_REQUEST,
                "view collections require a viewQuery",
            );
        };
        if !q.to_ascii_uppercase().starts_with("SELECT") || q.contains(';') || q.len() > 4096 {
            return pb_err(
                StatusCode::BAD_REQUEST,
                "viewQuery must be a single SELECT statement",
            );
        }
    }
    if pb.col_get(&name).is_some() {
        return pb_err(
            StatusCode::BAD_REQUEST,
            "a collection with this name already exists",
        );
    }
    let (fields, cols) = match normalize_fields_for(req.get("fields"), kind == "auth") {
        Ok(v) => v,
        Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
    };
    if kind == "view" {
        // a REAL SQLite view: filters/sorts/getOne flow through the normal
        // engine path; the records layer only blocks mutations
        let q = req
            .get("viewQuery")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim();
        if let Err(r) = exec_ddl(
            &state,
            format!("CREATE VIEW IF NOT EXISTS \"{name}\" AS {q}"),
        )
        .await
        {
            return r;
        }
    } else if let Err(r) = exec_ddl(&state, create_table_sql(&name, &cols)).await {
        return r;
    }
    if kind == "auth" {
        let idx = format!(
            "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_{name}_email\" ON \"{name}\" (\"email\")"
        );
        if let Err(r) = exec_ddl(&state, idx).await {
            return r;
        }
    }
    let rule = |k: &str| req.get(k).and_then(|v| v.as_str()).map(String::from);
    let mut options = serde_json::Map::new();
    for key in [
        "otp",
        "mfa",
        "passwordAuth",
        "oauth2",
        "authToken",
        "authRule",
        "manageRule",
        "viewQuery",
    ] {
        if let Some(v) = req.get(key) {
            options.insert(key.to_string(), v.clone());
        }
    }
    let col = Collection {
        id: format!("pbc_{}", pb_id()),
        name,
        kind,
        fields,
        options: Value::Object(options),
        list_rule: rule("listRule"),
        view_rule: rule("viewRule"),
        create_rule: rule("createRule"),
        update_rule: rule("updateRule"),
        delete_rule: rule("deleteRule"),
        indexes: req.get("indexes").cloned().unwrap_or_else(|| json!([])),
        created: pb_now(),
        updated: pb_now(),
    };
    if let Err(m) = pb.col_insert(&col) {
        return pb_err(StatusCode::BAD_REQUEST, &m);
    }
    pb.migration_record("create", &col);
    tracing::info!(target: "audit", event = "pb_collection_created", name = %col.name, "pb collection created");
    (StatusCode::OK, Json(col.to_json())).into_response()
}

/// GET /api/collections — paginated list (superuser).
async fn list(
    State(state): State<AppState>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    if let Err(r) = require_superuser(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let items: Vec<Value> = pb.col_list().iter().map(Collection::to_json).collect();
    (
        StatusCode::OK,
        Json(json!({
            "page": 1,
            "perPage": items.len().max(30),
            "totalItems": items.len(),
            "totalPages": 1,
            "items": items,
        })),
    )
        .into_response()
}

/// GET /api/collections/{idOrName} (superuser).
async fn view(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(id_or_name): Path<String>,
) -> axum::response::Response {
    if let Err(r) = require_superuser(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    match pb.col_get(&id_or_name) {
        Some(c) => (StatusCode::OK, Json(c.to_json())).into_response(),
        None => pb_err(StatusCode::NOT_FOUND, "collection not found"),
    }
}

/// PATCH /api/collections/{idOrName} — rules + additive fields (superuser).
async fn update(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(id_or_name): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    if let Err(r) = require_superuser(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(mut col) = pb.col_get(&id_or_name) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    if let Some(new_fields) = req.get("fields") {
        let (normalized, cols) = match normalize_fields(Some(new_fields)) {
            Ok(v) => v,
            Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
        };
        // Additive only until the Phase L migration engine: every existing
        // user column must still be present in the new set.
        let existing: Vec<String> = col
            .fields
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|f| f.get("system").and_then(|v| v.as_bool()) != Some(true))
                    .filter_map(|f| f.get("name").and_then(|v| v.as_str()).map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        let new_names: std::collections::HashSet<&str> =
            cols.iter().map(|(n, _)| n.as_str()).collect();
        for name in &existing {
            if !new_names.contains(name.as_str()) {
                return pb_err(
                    StatusCode::BAD_REQUEST,
                    &format!("removing/renaming field '{name}' requires the migrations engine (later phase); fields can only be added for now"),
                );
            }
        }
        for (name, ty) in &cols {
            if !existing.iter().any(|e| e == name) {
                let sql = format!("ALTER TABLE \"{}\" ADD COLUMN \"{name}\" {ty}", col.name);
                if let Err(r) = exec_ddl(&state, sql).await {
                    return r;
                }
            }
        }
        col.fields = normalized;
    }
    let rule = |k: &str, cur: &Option<String>| -> Option<String> {
        match req.get(k) {
            Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s.clone()),
            _ => cur.clone(),
        }
    };
    col.list_rule = rule("listRule", &col.list_rule);
    col.view_rule = rule("viewRule", &col.view_rule);
    col.create_rule = rule("createRule", &col.create_rule);
    col.update_rule = rule("updateRule", &col.update_rule);
    col.delete_rule = rule("deleteRule", &col.delete_rule);
    if let Some(idx) = req.get("indexes") {
        col.indexes = idx.clone();
    }
    for key in [
        "otp",
        "mfa",
        "passwordAuth",
        "oauth2",
        "authToken",
        "authRule",
        "manageRule",
    ] {
        if let Some(v) = req.get(key) {
            if let Some(o) = col.options.as_object_mut() {
                o.insert(key.to_string(), v.clone());
            }
        }
    }
    if let Err(m) = pb.col_update(&col) {
        return pb_err(StatusCode::BAD_REQUEST, &m);
    }
    pb.migration_record("update", &col);
    (
        StatusCode::OK,
        Json(
            pb.col_get(&col.id)
                .map(|c| c.to_json())
                .unwrap_or_else(|| col.to_json()),
        ),
    )
        .into_response()
}

/// DELETE /api/collections/{idOrName} (superuser) — registry row + table.
async fn remove(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(id_or_name): Path<String>,
) -> axum::response::Response {
    if let Err(r) = require_superuser(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(col) = pb.col_get(&id_or_name) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    let drop_sql = if col.kind == "view" {
        format!("DROP VIEW IF EXISTS \"{}\"", col.name)
    } else {
        format!("DROP TABLE IF EXISTS \"{}\"", col.name)
    };
    if let Err(r) = exec_ddl(&state, drop_sql).await {
        return r;
    }
    pb.col_delete(&col.id);
    pb.migration_record("delete", &col);
    tracing::info!(target: "audit", event = "pb_collection_deleted", name = %col.name, "pb collection deleted");
    StatusCode::NO_CONTENT.into_response()
}

/// PUT /api/collections/import {collections, deleteMissing?} — superuser.
/// Create-or-update each entry (additive field changes only, like PATCH);
/// deleteMissing removes collections absent from the payload.
async fn import(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<Value>,
) -> axum::response::Response {
    if let Err(r) = require_superuser(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(entries) = req.get("collections").and_then(|v| v.as_array()) else {
        return pb_err(StatusCode::BAD_REQUEST, "missing collections array");
    };
    let mut names = std::collections::HashSet::new();
    for entry in entries {
        let name = entry
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        names.insert(name.clone());
        let exists = pb.col_get(&name).is_some();
        let resp = if exists {
            update(
                State(state.clone()),
                headers.clone(),
                Path(name),
                Json(entry.clone()),
            )
            .await
        } else {
            create(State(state.clone()), headers.clone(), Json(entry.clone())).await
        };
        if resp.status().as_u16() >= 400 {
            return resp;
        }
    }
    if req
        .get("deleteMissing")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        for col in pb.col_list() {
            if !names.contains(&col.name) {
                let _ = remove(
                    State(state.clone()),
                    headers.clone(),
                    Path(col.name.clone()),
                )
                .await;
            }
        }
    }
    StatusCode::NO_CONTENT.into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/collections", post(create).get(list))
        .route("/api/collections/import", axum::routing::put(import))
        .route(
            "/api/collections/:id_or_name",
            get(view).patch(update).delete(remove),
        )
}
