//! Verb/path mapping helpers: route resolution, id extraction, query-string
//! assembly, percent-encoding, and base+path joining.

use super::validate::HttpConnection;
use data_plane_core::{DataOperation, DataPlaneError, DataPlaneResult};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use serde_json::Value;

pub(super) fn join_url(base: &str, path: &str) -> DataPlaneResult<String> {
    let clean_base = base.trim_end_matches('/');
    let clean_path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    Ok(format!("{clean_base}{clean_path}"))
}

pub(super) fn encode(s: &str) -> String {
    utf8_percent_encode(s, NON_ALPHANUMERIC).to_string()
}

pub(super) fn route_or_default<F: FnOnce() -> String>(
    conn: &HttpConnection,
    op_name: &str,
    default_path: F,
) -> String {
    conn.routes
        .as_ref()
        .and_then(|m| m.get(op_name))
        .cloned()
        .unwrap_or_else(default_path)
}

pub(super) fn scalar_id_from_filter(op: &DataOperation) -> DataPlaneResult<String> {
    let id = op
        .filter
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"));
    extract_scalar(id, "filter.id")
}

pub(super) fn scalar_id_from_filter_or_data(op: &DataOperation) -> DataPlaneResult<String> {
    let from_filter = op
        .filter
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"));
    let from_data = op
        .data
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"));
    extract_scalar(from_filter.or(from_data), "filter.id or data.id")
}

pub(super) fn extract_scalar(value: Option<&Value>, label: &str) -> DataPlaneResult<String> {
    match value {
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Number(n)) => Ok(n.to_string()),
        Some(Value::Bool(b)) => Ok(b.to_string()),
        _ => Err(DataPlaneError::InvalidRequest {
            message: format!("http op requires {label} as a string/number/bool"),
        }),
    }
}

pub(super) fn append_query(path: &str, op: &DataOperation) -> String {
    let mut params: Vec<(String, String)> = Vec::new();
    if let Some(Value::Object(map)) = op.filter.as_ref() {
        for (k, v) in map {
            if v.is_null() {
                continue;
            }
            let value_str = match v {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            params.push((k.clone(), value_str));
        }
    }
    if let Some(sort) = op.sort.as_ref() {
        params.push((
            "sort".to_string(),
            serde_json::to_string(sort).unwrap_or_default(),
        ));
    }
    if let Some(l) = op.limit {
        params.push(("limit".to_string(), l.to_string()));
    }
    if let Some(o) = op.offset {
        params.push(("offset".to_string(), o.to_string()));
    }
    if params.is_empty() {
        return path.to_string();
    }
    let qs: Vec<String> = params
        .iter()
        .map(|(k, v)| format!("{}={}", encode(k), encode(v)))
        .collect();
    let sep = if path.contains('?') { '&' } else { '?' };
    format!("{path}{sep}{}", qs.join("&"))
}
