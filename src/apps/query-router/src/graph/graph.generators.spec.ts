// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { generatedEdges } from './graph.generators';
import type { GraphNode } from './graph.types';

function node(data: Record<string, unknown>): GraphNode {
  return { id: 'db1:notes:1', mount: 'db1', resource: 'notes', pk: '1', data };
}

describe('generatedEdges', () => {
  it('returns nothing without a generator config', () => {
    expect(generatedEdges(node({}), undefined)).toEqual([]);
  });

  it('parses [[wikilinks]] from the configured note field (drops empty links)', () => {
    const edges = generatedEdges(
      node({ body: 'see [[db1:notes:2]] and [[ db1:notes:3 ]] plus [[]]' }),
      { noteField: 'body' },
    );
    expect(edges.map((e) => e.to)).toEqual(['db1:notes:2', 'db1:notes:3']);
    expect(edges[0]).toMatchObject({ type: 'note_link', from: 'db1:notes:1', directed: true });
  });

  it('a non-string note field yields no note edges', () => {
    expect(generatedEdges(node({ body: 42 }), { noteField: 'body' })).toEqual([]);
  });

  it('maps a string-array tag field to one edge per non-empty string tag', () => {
    const edges = generatedEdges(node({ tags: ['x', '', 'y', 7] }), {
      tags: { field: 'tags', mount: 'm', resource: 'tag' },
    });
    expect(edges.map((e) => e.to)).toEqual(['m:tag:x', 'm:tag:y']);
  });

  it('a non-array tag field yields no tag edges', () => {
    expect(
      generatedEdges(node({ tags: 'x' }), { tags: { field: 'tags', mount: 'm', resource: 'tag' } }),
    ).toEqual([]);
  });

  it('FK-by-declaration: scalar refs become edges; null/object/malformed are skipped', () => {
    const edges = generatedEdges(node({ author: 5, missing: null, obj: { a: 1 } }), {
      references: [
        { field: 'author', mount: 'm', resource: 'users' },
        { field: 'missing', mount: 'm', resource: 'users' }, // null → not scalar → skipped
        { field: 'obj', mount: 'm', resource: 'users' }, //     object → not scalar → continue (L63)
        { field: 123 as unknown as string, mount: 'm', resource: 'x' }, // bad field → continue (L61)
      ],
    });
    expect(edges).toHaveLength(1);
    expect(edges[0]).toMatchObject({ to: 'm:users:5', type: 'author', directed: true });
  });
});
