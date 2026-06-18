//! Phase D — node-graph assembly in Rust (the `/data/v1/graph` bypass).
//!
//! A faithful port of the query-router's `GraphService`: a node-link subgraph
//! built by composing owner-scoped `list` reads — no new engine work, no
//! cross-database join. Nodes + neighbours come from `get`/`list`; edges from
//! the dedicated `edges` mount plus secondary generators (note/tag/reference).
//! Every read goes through the same pool path as `/data/v1/query`, so tenant +
//! owner scoping apply for free: a row the caller cannot read is simply omitted
//! (the graph shows only what you may see). A cross-mount subgraph is several
//! atomic reads, so its honesty tier is `subgraph_eventual` (no global snapshot).
//!
//! Additive + bypass-gated: the app keeps using `/query/v1/graph`; this is the
//! shadow path proven row-for-row identical by the parity gate before any cutover.

use std::collections::{BTreeMap, HashMap, HashSet};

use axum::{extract::State, http::header, http::StatusCode, response::IntoResponse, Json};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use data_plane_core::{
    CredentialRef, DataOperation, DataOperationKind, DatabaseMount, IdentitySource, PoolPolicy,
    RequestIdentity,
};

use crate::routes::{api_err, bypass_verify, require_scope, scope_denied, AppState};

const MAX_DEPTH: u32 = 3;
const EDGE_FANOUT: u32 = 1000;
const DEFAULT_OVERVIEW_LIMIT: u32 = 500;
const MAX_OVERVIEW_LIMIT: u32 = 2000;
/// DoS bound: the most distinct nodes one graph request may materialise across
/// all hops. Beyond this the BFS stops — a safety cap well above any real graph.
const MAX_GRAPH_NODES: usize = 5000;

// ── Contract (in lockstep with the query-router graph.types.ts) ─────────────

#[derive(Debug, Clone, Serialize)]
pub struct GraphNode {
    pub id: String,
    pub mount: String,
    pub resource: String,
    pub pk: String,
    pub data: Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct EdgeRecord {
    pub id: String,
    pub from: String,
    pub to: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub directed: bool,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GraphGuarantee {
    PerNodeAtomic,
    SubgraphEventual,
}

#[derive(Debug, Serialize)]
pub struct GraphResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub focus: Option<String>,
    pub depth: u32,
    pub nodes: Vec<GraphNode>,
    pub edges: Vec<EdgeRecord>,
    pub guarantee: GraphGuarantee,
}

#[derive(Debug, Deserialize)]
pub struct ResourceRef {
    #[serde(rename = "dbId", alias = "db_id")]
    pub db_id: String,
    pub table: String,
}

#[derive(Debug, Deserialize)]
pub struct TagGenConfig {
    pub field: String,
    pub mount: String,
    pub resource: String,
}

#[derive(Debug, Deserialize)]
pub struct ReferenceGenConfig {
    pub field: String,
    pub mount: String,
    pub resource: String,
}

#[derive(Debug, Default, Deserialize)]
pub struct EdgeGenerators {
    #[serde(default, rename = "noteField")]
    pub note_field: Option<String>,
    #[serde(default)]
    pub tags: Option<TagGenConfig>,
    #[serde(default)]
    pub references: Option<Vec<ReferenceGenConfig>>,
}

#[derive(Debug, Deserialize)]
pub struct GraphRequest {
    pub focus: String,
    #[serde(default)]
    pub depth: Option<u32>,
    #[serde(rename = "edgesDbId", alias = "edges_db_id")]
    pub edges_db_id: String,
    #[serde(default, rename = "edgesTable", alias = "edges_table")]
    pub edges_table: Option<String>,
    #[serde(default)]
    pub generators: Option<EdgeGenerators>,
}

#[derive(Debug, Deserialize)]
pub struct GraphOverviewRequest {
    #[serde(default)]
    pub resources: Vec<ResourceRef>,
    #[serde(rename = "edgesDbId", alias = "edges_db_id")]
    pub edges_db_id: String,
    #[serde(default, rename = "edgesTable", alias = "edges_table")]
    pub edges_table: Option<String>,
    #[serde(default)]
    pub limit: Option<u32>,
    #[serde(default)]
    pub generators: Option<EdgeGenerators>,
}

// ── pure helpers ────────────────────────────────────────────────────────────

/// Split a `mount:resource:pk` id (`pk` may itself contain `:`). `None` on a
/// malformed id — the caller omits it rather than failing the whole graph.
fn parse_node_id(id: &str) -> Option<(String, String, String)> {
    let i1 = id.find(':')?;
    if i1 == 0 {
        return None;
    }
    let i2 = id[i1 + 1..].find(':').map(|i| i + i1 + 1)?;
    if i2 <= i1 || i2 == id.len() - 1 {
        return None;
    }
    Some((
        id[..i1].to_string(),
        id[i1 + 1..i2].to_string(),
        id[i2 + 1..].to_string(),
    ))
}

fn value_to_id_str(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    }
}

/// A row from the `edges` mount → an `EdgeRecord` (None if malformed).
fn to_edge_record(row: &Value) -> Option<EdgeRecord> {
    let from = row.get("from")?.as_str()?.to_string();
    let to = row.get("to")?.as_str()?.to_string();
    let id = value_to_id_str(row.get("id")).unwrap_or_else(|| format!("{from}->{to}"));
    Some(EdgeRecord {
        id,
        from,
        to,
        kind: row
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("linked")
            .to_string(),
        label: row.get("label").and_then(|v| v.as_str()).map(String::from),
        directed: row
            .get("directed")
            .and_then(|v| v.as_bool())
            .unwrap_or(true),
    })
}

/// A listed row → a node, keyed by its `id` column (the node PK convention).
fn row_to_node(db_id: &str, resource: &str, row: &Value) -> Option<GraphNode> {
    let pk = value_to_id_str(row.get("id"))?;
    Some(GraphNode {
        id: format!("{db_id}:{resource}:{pk}"),
        mount: db_id.to_string(),
        resource: resource.to_string(),
        pk,
        data: row.clone(),
    })
}

/// Secondary edge generators derived from a node's own data (note `[[wikilinks]]`,
/// tag arrays, FK-by-declaration references). Defensive: a malformed config
/// yields no edges rather than an error — mirrors the TS `generatedEdges`.
fn generated_edges(node: &GraphNode, gen: Option<&EdgeGenerators>) -> Vec<EdgeRecord> {
    let Some(gen) = gen else {
        return Vec::new();
    };
    let mut out = Vec::new();
    if let Some(field) = gen.note_field.as_deref() {
        out.extend(note_edges(node, field));
    }
    if let Some(tags) = gen.tags.as_ref() {
        out.extend(tag_edges(node, tags));
    }
    if let Some(refs) = gen.references.as_ref() {
        out.extend(reference_edges(node, refs));
    }
    out
}

/// Obsidian-style: every `[[NodeId]]` in a markdown note field → a `note_link`.
fn note_edges(node: &GraphNode, field: &str) -> Vec<EdgeRecord> {
    let Some(body) = node.data.get(field).and_then(|v| v.as_str()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut rest = body;
    while let Some(start) = rest.find("[[") {
        let after = &rest[start + 2..];
        let Some(end) = after.find("]]") else { break };
        let to = after[..end].trim();
        if !to.is_empty() {
            out.push(EdgeRecord {
                id: format!("note:{}|{}", node.id, to),
                from: node.id.clone(),
                to: to.to_string(),
                kind: "note_link".to_string(),
                label: None,
                directed: true,
            });
        }
        rest = &after[end + 2..];
    }
    out
}

fn tag_edges(node: &GraphNode, cfg: &TagGenConfig) -> Vec<EdgeRecord> {
    let Some(arr) = node.data.get(&cfg.field).and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|t| t.as_str())
        .filter(|s| !s.is_empty())
        .map(|tag| EdgeRecord {
            id: format!("tag:{}|{}", node.id, tag),
            from: node.id.clone(),
            to: format!("{}:{}:{}", cfg.mount, cfg.resource, tag),
            kind: "tagged".to_string(),
            label: None,
            directed: true,
        })
        .collect()
}

fn reference_edges(node: &GraphNode, refs: &[ReferenceGenConfig]) -> Vec<EdgeRecord> {
    let mut out = Vec::new();
    for r in refs {
        let scalar = match node.data.get(&r.field) {
            Some(Value::String(s)) => Some(s.clone()),
            Some(Value::Number(n)) => Some(n.to_string()),
            Some(Value::Bool(b)) => Some(b.to_string()),
            _ => None, // null / object / array / missing → skip (matches TS)
        };
        let Some(val) = scalar else { continue };
        out.push(EdgeRecord {
            id: format!("ref:{}|{}", node.id, r.field),
            from: node.id.clone(),
            to: format!("{}:{}:{}", r.mount, r.resource, val),
            kind: r.field.clone(),
            label: None,
            directed: true,
        });
    }
    out
}

// ── the engine (BFS over owner-scoped reads, per-request mount cache) ────────

#[derive(Clone)]
struct CachedMount {
    engine: String,
    dsn: String,
    isolation: Option<String>,
    overrides: Option<Value>,
}

struct GraphEngine<'a> {
    state: &'a AppState,
    id: &'a crate::auth::VerifiedIdentity,
    cache: HashMap<String, Option<CachedMount>>,
}

impl<'a> GraphEngine<'a> {
    fn new(state: &'a AppState, id: &'a crate::auth::VerifiedIdentity) -> Self {
        Self {
            state,
            id,
            cache: HashMap::new(),
        }
    }

    /// Resolve a mount for `db_id` (tenant-scoped via adapter-registry), cached
    /// per request so a graph that stays in one mount resolves it once.
    async fn resolve(&mut self, db_id: &str) -> Option<CachedMount> {
        if let Some(c) = self.cache.get(db_id) {
            return c.clone();
        }
        let cm = self
            .state
            .resolve_bypass_mount(&self.id.tenant_id, db_id)
            .await
            .ok()
            .map(|m| CachedMount {
                engine: m.engine,
                dsn: m.connection_string,
                isolation: m.isolation,
                overrides: m.capability_overrides,
            });
        self.cache.insert(db_id.to_string(), cm.clone());
        cm
    }

    /// One owner-scoped `list` read. Errors (and unresolvable mounts) yield no
    /// rows — the graph shows only what the caller may read.
    async fn read(
        &mut self,
        db_id: &str,
        resource: &str,
        filter: Option<Value>,
        limit: u32,
    ) -> Vec<Value> {
        let Some(cm) = self.resolve(db_id).await else {
            return Vec::new();
        };
        let identity = RequestIdentity {
            tenant_id: self.id.tenant_id.clone(),
            project_id: None,
            app_id: None,
            user_id: Some(format!("api-key:{}", self.id.key_id)),
            roles: Vec::new(),
            scopes: self.id.scopes.clone(),
            source: IdentitySource::ServiceToken,
        };
        let mount = DatabaseMount {
            id: db_id.to_string(),
            tenant_id: self.id.tenant_id.clone(),
            project_id: None,
            engine: cm.engine.clone(),
            name: "graph".to_string(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".to_string(),
                reference: db_id.to_string(),
                version: "live".to_string(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: cm.overrides.clone(),
            inline_dsn: Some(cm.dsn.clone()),
            isolation: cm.isolation.clone(),
            replica_inline_dsn: None,
            read_replica_route: false,
        };
        let op = DataOperation {
            op: DataOperationKind::List,
            resource: resource.to_string(),
            data: None,
            filter,
            sort: None,
            limit: Some(limit),
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        self.state
            .execute_read(identity, mount, op)
            .await
            .map(|r| r.rows)
            .unwrap_or_default()
    }

    async fn fetch_node(&mut self, node_id: &str) -> Option<GraphNode> {
        let (db_id, resource, pk) = parse_node_id(node_id)?;
        let rows = self
            .read(&db_id, &resource, Some(json!({ "id": pk })), 1)
            .await;
        let row = rows.into_iter().next()?;
        Some(GraphNode {
            id: node_id.to_string(),
            mount: db_id,
            resource,
            pk,
            data: row,
        })
    }

    async fn fetch_edges(
        &mut self,
        node_id: &str,
        edges_db_id: &str,
        edges_table: &str,
    ) -> Vec<EdgeRecord> {
        let filter = json!({ "$or": [{ "from": node_id }, { "to": node_id }] });
        self.read(edges_db_id, edges_table, Some(filter), EDGE_FANOUT)
            .await
            .iter()
            .filter_map(to_edge_record)
            .collect()
    }

    async fn derive(&mut self, req: GraphRequest) -> GraphResponse {
        let depth = req.depth.unwrap_or(1).min(MAX_DEPTH);
        let edges_table = req
            .edges_table
            .clone()
            .unwrap_or_else(|| "edges".to_string());
        let mut nodes: BTreeMap<String, GraphNode> = BTreeMap::new();
        let mut edges: BTreeMap<String, EdgeRecord> = BTreeMap::new();
        let mut visited: HashSet<String> = HashSet::new();
        let mut frontier = vec![req.focus.clone()];

        'bfs: for d in 0..=depth {
            let expand = d < depth;
            let mut next: Vec<String> = Vec::new();
            for node_id in std::mem::take(&mut frontier) {
                if !visited.insert(node_id.clone()) {
                    continue;
                }
                let Some(node) = self.fetch_node(&node_id).await else {
                    continue; // unreadable / missing → omit
                };
                nodes.insert(node_id.clone(), node.clone());
                if nodes.len() >= MAX_GRAPH_NODES {
                    break 'bfs; // DoS bound
                }
                if expand {
                    let mut neigh = self
                        .fetch_edges(&node_id, &req.edges_db_id, &edges_table)
                        .await;
                    neigh.extend(generated_edges(&node, req.generators.as_ref()));
                    for e in neigh {
                        let other = if e.from == node_id {
                            e.to.clone()
                        } else {
                            e.from.clone()
                        };
                        edges.insert(e.id.clone(), e);
                        if !visited.contains(&other) {
                            next.push(other);
                        }
                    }
                }
            }
            frontier = next;
        }

        GraphResponse {
            focus: Some(req.focus),
            depth,
            nodes: nodes.into_values().collect(),
            edges: edges.into_values().collect(),
            guarantee: if depth == 0 {
                GraphGuarantee::PerNodeAtomic
            } else {
                GraphGuarantee::SubgraphEventual
            },
        }
    }

    async fn overview(&mut self, req: GraphOverviewRequest) -> GraphResponse {
        let limit = req
            .limit
            .unwrap_or(DEFAULT_OVERVIEW_LIMIT)
            .clamp(1, MAX_OVERVIEW_LIMIT);
        let edges_table = req
            .edges_table
            .clone()
            .unwrap_or_else(|| "edges".to_string());
        let mut nodes: BTreeMap<String, GraphNode> = BTreeMap::new();
        'ov: for rf in &req.resources {
            for row in self.read(&rf.db_id, &rf.table, None, limit).await {
                if let Some(n) = row_to_node(&rf.db_id, &rf.table, &row) {
                    nodes.insert(n.id.clone(), n);
                    if nodes.len() >= MAX_GRAPH_NODES {
                        break 'ov; // DoS bound
                    }
                }
            }
        }
        let mut edges: BTreeMap<String, EdgeRecord> = BTreeMap::new();
        for row in self
            .read(&req.edges_db_id, &edges_table, None, EDGE_FANOUT)
            .await
        {
            if let Some(e) = to_edge_record(&row) {
                edges.insert(e.id.clone(), e);
            }
        }
        for n in nodes.values() {
            for e in generated_edges(n, req.generators.as_ref()) {
                edges.insert(e.id.clone(), e);
            }
        }
        GraphResponse {
            focus: None,
            depth: 0,
            nodes: nodes.into_values().collect(),
            edges: edges.into_values().collect(),
            guarantee: GraphGuarantee::SubgraphEventual,
        }
    }
}

// ── handlers (api-key authed, read scope) ────────────────────────────────────

pub async fn data_graph(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<GraphRequest>,
) -> axum::response::Response {
    let id = match bypass_verify(&state, &headers).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if let Err(missing) = require_scope(&id.scopes, "read") {
        return scope_denied(&id, "graph", missing);
    }
    if req.focus.trim().is_empty() {
        return api_err(StatusCode::BAD_REQUEST, "bad_request", "focus is required");
    }
    // Rate-limit the (multi-read) graph as ONE request on the focus mount's tier
    // mask — the graph bypass path doesn't go through run_query's limiter.
    let primary = parse_node_id(&req.focus)
        .map(|(db, _, _)| db)
        .unwrap_or_else(|| req.edges_db_id.clone());
    let overrides = state
        .resolve_bypass_mount(&id.tenant_id, &primary)
        .await
        .ok()
        .and_then(|m| m.capability_overrides);
    if let Err(resp) =
        crate::routes::bypass_ratelimit(&state, &id.tenant_id, overrides.as_ref(), "graph").await
    {
        return resp;
    }
    let graph = GraphEngine::new(&state, &id).derive(req).await;
    (StatusCode::OK, Json(graph)).into_response()
}

pub async fn data_graph_overview(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<GraphOverviewRequest>,
) -> axum::response::Response {
    let id = match bypass_verify(&state, &headers).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if let Err(missing) = require_scope(&id.scopes, "read") {
        return scope_denied(&id, "graph", missing);
    }
    let overrides = state
        .resolve_bypass_mount(&id.tenant_id, &req.edges_db_id)
        .await
        .ok()
        .and_then(|m| m.capability_overrides);
    if let Err(resp) =
        crate::routes::bypass_ratelimit(&state, &id.tenant_id, overrides.as_ref(), "graph").await
    {
        return resp;
    }
    let graph = GraphEngine::new(&state, &id).overview(req).await;
    (StatusCode::OK, Json(graph)).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_node_id_splits_on_first_two_colons() {
        let (m, r, pk) = parse_node_id("db1:notes:42").unwrap();
        assert_eq!(
            (m.as_str(), r.as_str(), pk.as_str()),
            ("db1", "notes", "42")
        );
        // pk may contain colons
        let (_, _, pk2) = parse_node_id("db1:notes:a:b:c").unwrap();
        assert_eq!(pk2, "a:b:c");
        assert!(parse_node_id("nope").is_none());
        assert!(parse_node_id(":x:y").is_none());
        assert!(parse_node_id("db:notes:").is_none());
    }

    #[test]
    fn edge_record_falls_back_to_from_arrow_to() {
        let e = to_edge_record(&json!({ "from": "a", "to": "b" })).unwrap();
        assert_eq!(e.id, "a->b");
        assert_eq!(e.kind, "linked");
        assert!(e.directed);
        assert!(to_edge_record(&json!({ "from": 1, "to": "b" })).is_none());
    }

    #[test]
    fn note_generator_extracts_wikilinks() {
        let node = GraphNode {
            id: "db:n:1".into(),
            mount: "db".into(),
            resource: "n".into(),
            pk: "1".into(),
            data: json!({ "body": "see [[db:n:2]] and [[db:n:3]] end" }),
        };
        let gen = EdgeGenerators {
            note_field: Some("body".into()),
            ..Default::default()
        };
        let edges = generated_edges(&node, Some(&gen));
        assert_eq!(edges.len(), 2);
        assert_eq!(edges[0].to, "db:n:2");
        assert_eq!(edges[0].kind, "note_link");
    }

    #[test]
    fn reference_generator_skips_objects_and_nulls() {
        let node = GraphNode {
            id: "db:o:1".into(),
            mount: "db".into(),
            resource: "o".into(),
            pk: "1".into(),
            data: json!({ "customer_id": "c9", "meta": {"x":1}, "void": null }),
        };
        let refs = vec![
            ReferenceGenConfig {
                field: "customer_id".into(),
                mount: "db".into(),
                resource: "customers".into(),
            },
            ReferenceGenConfig {
                field: "meta".into(),
                mount: "db".into(),
                resource: "m".into(),
            },
            ReferenceGenConfig {
                field: "void".into(),
                mount: "db".into(),
                resource: "v".into(),
            },
        ];
        let edges = reference_edges(&node, &refs);
        assert_eq!(edges.len(), 1);
        assert_eq!(edges[0].to, "db:customers:c9");
        assert_eq!(edges[0].kind, "customer_id");
    }
}
