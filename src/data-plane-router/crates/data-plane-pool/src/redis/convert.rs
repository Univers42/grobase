/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   convert.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:39 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:41 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Value shaping + key/id derivation helpers — pure (no I/O) so the key
//! envelope and JSON round-trip are unit-testable without a live Redis.

use super::validate::validate_id;
use data_plane_core::{DataOperation, DataPlaneError, DataPlaneResult, DatabaseMount};
use serde_json::{Map as JsonMap, Value};

/// The key prefix, optionally namespaced. Pure (no I/O, no `self`) so the
/// envelope shape is unit-testable without a live Redis connection.
pub(super) fn build_key_prefix(namespace: Option<&str>, owner: &str, resource: &str) -> String {
    match namespace {
        Some(ns) => format!("{ns}:{owner}:{resource}"),
        None => format!("{owner}:{resource}"),
    }
}

pub(super) fn backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    DataPlaneError::Backend {
        message: format!("redis backend: {e}"),
    }
}

/// Per-tenant key-prefix segment for a `schema_per_tenant` Redis mount —
/// delegates to the single source of truth, [`DatabaseMount::resolve_namespace`].
// ponytail: thin wrapper kept so call sites read `resolve_namespace(&mount)`;
// inline + delete in a follow-up.
pub(super) fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    mount.resolve_namespace()
}

/// Split `op.data` into `(id, remaining_fields)`. If `allow_generate` is true
/// and no id is provided, generates one ({ms}-{random}).
pub(super) fn split_id_data(
    op: &DataOperation,
    allow_generate: bool,
) -> DataPlaneResult<(String, JsonMap<String, Value>)> {
    let Some(Value::Object(map)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "redis op requires data as a JSON object".to_string(),
        });
    };
    let mut rest = map.clone();
    let id_value = op
        .filter
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"))
        .cloned()
        .or_else(|| rest.remove("id"));
    let id = match id_value {
        Some(Value::String(s)) => s,
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(_) => {
            return Err(DataPlaneError::InvalidRequest {
                message: "redis id must be a string/number/bool".to_string(),
            });
        }
        None if allow_generate => generate_id(),
        None => {
            return Err(DataPlaneError::InvalidRequest {
                message: "redis update requires filter.id or data.id".to_string(),
            });
        }
    };
    validate_id(&id)?;
    rest.remove("id");
    Ok((id, rest))
}

pub(super) fn generate_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    // Plain counter is fine — the key is then namespaced under owner+resource
    // so cross-mount collisions are impossible.
    format!("{ms}-{:08x}", fastrand_u32())
}

fn fastrand_u32() -> u32 {
    use std::cell::Cell;
    use std::time::{SystemTime, UNIX_EPOCH};
    // Tiny xorshift seeded from nanoseconds — not crypto, just enough for ids.
    thread_local! {
        static STATE: Cell<u32> = const { Cell::new(0) };
    }
    STATE.with(|s| {
        let mut x = s.get();
        if x == 0 {
            x = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or(1)
                | 1;
        }
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        s.set(x);
        x
    })
}

pub(super) fn value_to_hash_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

pub(super) fn hash_to_row(id: String, hash: std::collections::HashMap<String, String>) -> Value {
    let mut row = JsonMap::with_capacity(hash.len() + 1);
    row.insert("id".to_string(), Value::String(id));
    for (k, v) in hash {
        let parsed = serde_json::from_str(&v).unwrap_or(Value::String(v));
        row.insert(k, parsed);
    }
    Value::Object(row)
}
