/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:45 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Per-operation executors (list/get/insert/update/delete/upsert) against a
//! live `ConnectionManager`, plus the hash-write helper they share.

use super::convert::{backend, hash_to_row, split_id_data, value_to_hash_string};
use super::pool::RedisPool;
use super::validate::validate_id;
use data_plane_core::{DataOperation, DataPlaneError, DataPlaneResult, DataResult};
use redis::aio::ConnectionManager;
use redis::AsyncCommands;
use serde_json::{Map as JsonMap, Value};

pub(super) async fn run_list(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let limit = op.limit.unwrap_or(100).min(500) as usize;
    let offset = op.offset.unwrap_or(0) as usize;
    let pattern = format!("{prefix}:*");

    // SCAN with MATCH avoids blocking the server unlike KEYS.
    let mut keys: Vec<String> = Vec::new();
    let mut iter = conn
        .scan_match::<_, String>(&pattern)
        .await
        .map_err(backend)?;
    while let Some(k) = futures::StreamExt::next(&mut iter).await {
        keys.push(k);
        if keys.len() > limit + offset {
            break;
        }
    }
    drop(iter);
    keys.sort();
    let slice = keys
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect::<Vec<_>>();
    if slice.is_empty() {
        return Ok(DataResult::new(vec![], 0));
    }

    let mut rows: Vec<Value> = Vec::with_capacity(slice.len());
    let prefix_with_sep = format!("{prefix}:");
    for k in &slice {
        let hash: std::collections::HashMap<String, String> =
            conn.hgetall(k).await.map_err(backend)?;
        if hash.is_empty() {
            continue;
        }
        let id = k.strip_prefix(&prefix_with_sep).unwrap_or(k).to_string();
        rows.push(hash_to_row(id, hash));
    }
    let affected = rows.len() as u64;
    Ok(DataResult::new(rows, affected))
}

pub(super) async fn run_get(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let id = RedisPool::id_from_filter_or_data(op)?;
    validate_id(&id)?;
    let key = format!("{prefix}:{id}");
    let hash: std::collections::HashMap<String, String> =
        conn.hgetall(&key).await.map_err(backend)?;
    if hash.is_empty() {
        return Ok(DataResult::new(vec![], 0));
    }
    Ok(DataResult::new(vec![hash_to_row(id, hash)], 1))
}

pub(super) async fn run_insert(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let (id, mut data) = split_id_data(op, /*allow_generate=*/ true)?;
    let key = format!("{prefix}:{id}");
    let exists: bool = conn.exists(&key).await.map_err(backend)?;
    if exists {
        return Err(DataPlaneError::Backend {
            message: format!("redis key already exists: {key}"),
        });
    }
    write_hash(conn, &key, &data).await?;
    data.insert("id".to_string(), Value::String(id));
    Ok(DataResult::new(vec![Value::Object(data)], 1))
}

pub(super) async fn run_update(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let (id, mut data) = split_id_data(op, /*allow_generate=*/ false)?;
    let key = format!("{prefix}:{id}");
    let exists: bool = conn.exists(&key).await.map_err(backend)?;
    if !exists {
        return Ok(DataResult::new(vec![], 0));
    }
    write_hash(conn, &key, &data).await?;
    data.insert("id".to_string(), Value::String(id));
    Ok(DataResult::new(vec![Value::Object(data)], 1))
}

pub(super) async fn run_delete(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let id = RedisPool::id_from_filter_or_data(op)?;
    validate_id(&id)?;
    let key = format!("{prefix}:{id}");
    let removed: u64 = conn.del(&key).await.map_err(backend)?;
    Ok(DataResult::new(vec![], removed))
}

pub(super) async fn run_upsert(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let (id, mut data) = split_id_data(op, /*allow_generate=*/ true)?;
    let key = format!("{prefix}:{id}");
    write_hash(conn, &key, &data).await?;
    data.insert("id".to_string(), Value::String(id));
    Ok(DataResult::new(vec![Value::Object(data)], 1))
}

async fn write_hash(
    conn: &mut ConnectionManager,
    key: &str,
    data: &JsonMap<String, Value>,
) -> DataPlaneResult<()> {
    if data.is_empty() {
        return Ok(());
    }
    let pairs: Vec<(String, String)> = data
        .iter()
        .map(|(k, v)| (k.clone(), value_to_hash_string(v)))
        .collect();
    // hset_multiple expects Vec<(K, V)> for the field/value pairs.
    let _: () = conn.hset_multiple(key, &pairs).await.map_err(backend)?;
    Ok(())
}
