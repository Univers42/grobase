// Shared node-graph contract — the FROZEN handshake between the BaaS `/graph`
// endpoint (this service) and the osionos client (graphModel.ts / deriveGraph).
// Keep this file in lockstep with apps/osionos/app's graph model; any change
// here is a contract change both sides must agree on.

import { BadRequestException } from '@nestjs/common';

/** Global node identity: `<mountId>:<resource>:<pk>` — the BaaS addressing. */
export type NodeId = string;

/** A node = one row/record from any backend, normalised to JSON. */
export interface GraphNode {
  id: NodeId;
  mount: string;
  resource: string;
  pk: string;
  data: Record<string, unknown>;
  /** Optional note body (markdown) — website-dependent, not populated here. */
  note?: string;
}

/** An edge = a row in the dedicated `edges` mount (the PRIMARY edge source). */
export interface EdgeRecord {
  id: string;
  from: NodeId;
  to: NodeId;
  type: string;
  label?: string;
  directed?: boolean;
}

/** `node.data[field]` (a value) → edge to `<mount>:<resource>:<value>`. The
 *  FK-by-declaration / soft-reference generator (no schema introspection). */
export interface ReferenceGenConfig {
  field: string;
  mount: string;
  resource: string;
}

/** `node.data[field]` (a string array) → an edge per tag to a tag node. */
export interface TagGenConfig {
  field: string;
  mount: string;
  resource: string;
}

/** A node source for the global `/graph/overview`: one resource on one mount. */
export interface ResourceRef {
  dbId: string;
  table: string;
}

/** Secondary edge generators (all optional, all emit the same `EdgeRecord`
 *  shape into the response alongside the primary explicit edges). */
export interface EdgeGenerators {
  /** Parse `[[NodeId]]` wikilinks in `node.data[noteField]` (Obsidian-style). */
  noteField?: string;
  tags?: TagGenConfig;
  references?: ReferenceGenConfig[];
}

/**
 * The consistency tier actually delivered (honest, per doc-02):
 * - `per_node_atomic`    — a single record read (depth 0)
 * - `subgraph_eventual`  — a multi-read subgraph spanning mounts (depth ≥ 1)
 */
export type GraphGuarantee = 'per_node_atomic' | 'subgraph_eventual';

export interface GraphResponse {
  /** The focus node for a local graph; absent for the global `/graph/overview`. */
  focus?: NodeId;
  depth: number;
  nodes: GraphNode[];
  edges: EdgeRecord[];
  guarantee: GraphGuarantee;
}

/** Split a `mount:resource:pk` id; `pk` may itself contain `:`. */
export function parseNodeId(id: NodeId): { dbId: string; resource: string; pk: string } {
  const i1 = id.indexOf(':');
  const i2 = i1 < 0 ? -1 : id.indexOf(':', i1 + 1);
  if (i1 <= 0 || i2 <= i1 || i2 === id.length - 1) {
    throw new BadRequestException(`invalid node id '${id}' (expected mount:resource:pk)`);
  }
  return { dbId: id.slice(0, i1), resource: id.slice(i1 + 1, i2), pk: id.slice(i2 + 1) };
}

export const formatNodeId = (dbId: string, resource: string, pk: string): NodeId =>
  `${dbId}:${resource}:${pk}`;

/** Coerce a row from the `edges` mount into an `EdgeRecord` (null if malformed). */
export function toEdgeRecord(row: Record<string, unknown>): EdgeRecord | null {
  const from = row.from;
  const to = row.to;
  if (typeof from !== 'string' || typeof to !== 'string') return null;
  const rawId = row.id;
  const id =
    typeof rawId === 'string' || typeof rawId === 'number' ? String(rawId) : `${from}->${to}`;
  return {
    id,
    from,
    to,
    type: typeof row.type === 'string' ? row.type : 'linked',
    label: typeof row.label === 'string' ? row.label : undefined,
    directed: typeof row.directed === 'boolean' ? row.directed : true,
  };
}
