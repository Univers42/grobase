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

const WIKILINK = /\[\[([^\]]+)\]\]/g;

/** Obsidian-style: parse `[[NodeId]]` links from a markdown note field. */
function noteEdges(node: GraphNode, field: string): EdgeRecord[] {
  const body = node.data[field];
  if (typeof body !== 'string') return [];
  const out: EdgeRecord[] = [];
  for (const match of body.matchAll(WIKILINK)) {
    const to = match[1].trim();
    if (to) {
      out.push({ id: `note:${node.id}|${to}`, from: node.id, to, type: 'note_link', directed: true });
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

/** FK-by-declaration: a scalar field value → an edge to `<mount>:<resource>:<value>`. */
function referenceEdges(node: GraphNode, refs: ReferenceGenConfig[]): EdgeRecord[] {
  const out: EdgeRecord[] = [];
  for (const ref of refs) {
    if (!ref || typeof ref.field !== 'string') continue;
    const value = node.data[ref.field];
    if (value === null || value === undefined || typeof value === 'object') continue;
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
