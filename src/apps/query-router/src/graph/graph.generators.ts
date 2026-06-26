// Secondary edge generators — pure functions that derive `EdgeRecord`s from a
// node's own data, alongside the PRIMARY explicit edges (the `edges` mount).
// Every generator emits the same `EdgeRecord` shape, so the client never knows
// which generator produced an edge. No new backend capability, no schema
// introspection — relationships are declared per request.

import {
  EdgeGenerators,
  EdgeRecord,
  GraphNode,
  ReferenceGenConfig,
  TagGenConfig,
} from './graph.types';

// Atomic group `(?=(...))\1` makes the inner `[^\]]+` non-backtracking — it
// matches the same valid `[[…]]` links but cannot retry on unterminated input.
const WIKILINK = /\[\[(?=([^\]]+))\1\]\]/g;

/** Obsidian-style: parse `[[NodeId]]` links from a markdown note field. */
function noteEdges(node: GraphNode, field: string): EdgeRecord[] {
  const body = node.data[field];
  if (typeof body !== 'string') return [];
  const out: EdgeRecord[] = [];
  for (const match of body.matchAll(WIKILINK)) {
    const to = match[1].trim();
    if (to) {
      out.push({
        id: `note:${node.id}|${to}`,
        from: node.id,
        to,
        type: 'note_link',
        directed: true,
      });
    }
  }
  return out;
}

/** A string-array field → an edge per tag to a tag node `<mount>:<resource>:<tag>`. */
function tagEdges(node: GraphNode, cfg: TagGenConfig): EdgeRecord[] {
  const tags = node.data[cfg.field];
  if (!Array.isArray(tags)) return [];
  return tags
    .filter((tag): tag is string => typeof tag === 'string' && tag.length > 0)
    .map((tag) => ({
      id: `tag:${node.id}|${tag}`,
      from: node.id,
      to: `${cfg.mount}:${cfg.resource}:${tag}`,
      type: 'tagged',
      directed: true,
    }));
}

/** A scalar `node.data[field]` (anything but null/undefined/object) → a stable
 *  string for the FK-by-declaration edge target. `String(...)` over a confirmed
 *  primitive can never collapse to `[object Object]`. */
type ScalarValue = string | number | boolean | bigint | symbol;

function isScalar(value: unknown): value is ScalarValue {
  return value !== null && value !== undefined && typeof value !== 'object';
}

/** FK-by-declaration: a scalar field value → an edge to `<mount>:<resource>:<value>`. */
function referenceEdges(node: GraphNode, refs: ReferenceGenConfig[]): EdgeRecord[] {
  const out: EdgeRecord[] = [];
  for (const ref of refs) {
    if (!ref || typeof ref.field !== 'string') continue;
    const value = node.data[ref.field];
    if (!isScalar(value)) continue;
    out.push({
      id: `ref:${node.id}|${ref.field}`,
      from: node.id,
      to: `${ref.mount}:${ref.resource}:${String(value)}`,
      type: ref.field,
      directed: true,
    });
  }
  return out;
}

/** Tenancy/ownership stamp columns that look like FKs but are not graph-worthy
 *  relations (they would collapse every record onto one owner/tenant hub). */
function isFkStamp(field: string): boolean {
  return field === 'owner_id' || field === 'tenant_id';
}

/** Candidate table names for a FK base, matched against a mount's real resources:
 *  `customer`→[customer, customers]; `company`→[…, companies]; `box`→[…, boxes]. */
function pluralCandidates(base: string): string[] {
  const out = [base, `${base}s`];
  if (/[^aeiou]y$/.test(base)) out.push(`${base.slice(0, -1)}ies`);
  if (/(s|x|z|ch|sh)$/.test(base)) out.push(`${base}es`);
  return out;
}

/** The reference base of a key column — `<base>_id` or `<base>_ref` — else null. */
function fkBase(field: string): string | null {
  if (isFkStamp(field)) return null;
  if (field.endsWith('_id') && field.length > 3) return field.slice(0, -3);
  if (field.endsWith('_ref') && field.length > 4) return field.slice(0, -4);
  return null;
}

/** Resolve a FK base to a real `{mount, resource}`: prefer the node's OWN mount (an
 *  intra-cluster link), else the single OTHER mount that owns the table (a thin
 *  cross-cluster link — an edge, never a record copy). Ambiguous (≥2 other mounts)
 *  or unknown → null. */
function resolveTarget(
  ownMount: string,
  base: string,
  byMount: Map<string, Set<string>>,
): { mount: string; resource: string } | null {
  const cands = pluralCandidates(base);
  const own = byMount.get(ownMount);
  const ownHit = own && cands.find((c) => own.has(c));
  if (ownHit) return { mount: ownMount, resource: ownHit };
  let hit: { mount: string; resource: string } | null = null;
  let n = 0;
  for (const [mount, set] of byMount) {
    const r = cands.find((c) => set.has(c));
    if (r) {
      hit = { mount, resource: r };
      n += 1;
    }
  }
  return n === 1 ? hit : null;
}

/** Polymorphic reference: a `<p>_kind`/`<p>_type` field naming the target table,
 *  paired with the pk in `<p>_id`/`<p>_ref`/`related_id` (e.g. a note's
 *  `related_kind='order'` + `related_id`). Resolves the named table across mounts. */
function polymorphicEdge(
  node: GraphNode,
  field: string,
  byMount: Map<string, Set<string>>,
): EdgeRecord | null {
  const kind = node.data[field];
  if (typeof kind !== 'string' || !kind) return null;
  const prefix = field.replace(/_(kind|type)$/, '');
  const pk = node.data[`${prefix}_id`] ?? node.data[`${prefix}_ref`] ?? node.data.related_id;
  if (!isScalar(pk)) return null;
  const target = resolveTarget(node.mount, kind, byMount);
  if (!target) return null;
  const to = `${target.mount}:${target.resource}:${String(pk)}`;
  return to === node.id ? null : { id: `poly:${node.id}|${field}`, from: node.id, to, type: kind, directed: true };
}

/** Key edges (engine-agnostic, no schema introspection): turn every reference a
 *  record carries into an edge to the record it points at — `<base>_id`/`<base>_ref`
 *  columns and `<p>_kind`+`<p>_id` polymorphic pairs. A target resolves to a real
 *  table on the SAME mount first (dense intra-cluster links), else the one other
 *  mount that owns it (a thin cross-cluster link); records are never copied across
 *  databases. `byMount` (mount → its tables) is the only context — no catalog read. */
export function conventionEdges(node: GraphNode, byMount: Map<string, Set<string>>): EdgeRecord[] {
  const out: EdgeRecord[] = [];
  for (const [field, value] of Object.entries(node.data)) {
    if (/_(kind|type)$/.test(field)) {
      const edge = polymorphicEdge(node, field, byMount);
      if (edge) out.push(edge);
      continue;
    }
    const base = fkBase(field);
    if (!base || !isScalar(value)) continue;
    const target = resolveTarget(node.mount, base, byMount);
    if (!target) continue;
    const to = `${target.mount}:${target.resource}:${String(value)}`;
    if (to === node.id) continue;
    out.push({ id: `key:${node.id}|${field}`, from: node.id, to, type: field, directed: true });
  }
  return out;
}

/** Run every configured secondary generator for one node. Defensive: a malformed
 *  generator config yields no edges rather than an error. */
export function generatedEdges(node: GraphNode, gen: EdgeGenerators | undefined): EdgeRecord[] {
  if (!gen) return [];
  const out: EdgeRecord[] = [];
  if (typeof gen.noteField === 'string') out.push(...noteEdges(node, gen.noteField));
  if (gen.tags && typeof gen.tags.field === 'string') out.push(...tagEdges(node, gen.tags));
  if (Array.isArray(gen.references)) out.push(...referenceEdges(node, gen.references));
  return out;
}
