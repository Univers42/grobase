import { json, type RequestHandler } from 'express';

// The JSON body cap is per collection: every collection keeps the 100 KB default, and only
// the ones named in MONGO_API_BIG_COLLECTIONS (a whiteboard scene is one document of up to
// a few MB) take the larger limit. Empty by default, so nothing changes until an operator
// names a collection.

const COLLECTION_NAME = /^[\w-]{1,64}$/;
const DOCUMENTS_PATH = /^\/collections\/([\w-]{1,64})\/documents(?:\/|$)/;

export const DEFAULT_JSON_LIMIT = '100kb';
export const DEFAULT_BIG_JSON_LIMIT = '8mb';

/** The collection names in a comma-separated list; malformed names are dropped. */
export function parseBigCollections(raw: string | undefined): ReadonlySet<string> {
  const names = (raw ?? '').split(',').map((name) => name.trim());
  return new Set(names.filter((name) => COLLECTION_NAME.test(name)));
}

/** The collection a documents route addresses, or null for any other path. */
export function documentsCollection(path: string): string | null {
  return DOCUMENTS_PATH.exec(path)?.[1] ?? null;
}

/** One JSON parser for the whole app that picks the limit by the addressed collection. */
export function jsonBodyParser(
  bigCollections: ReadonlySet<string>,
  bigLimit: string,
): RequestHandler {
  const normal = json({ limit: DEFAULT_JSON_LIMIT });
  const big = json({ limit: bigLimit });
  return (req, res, next) => {
    const collection = documentsCollection(req.path);
    const parser = collection !== null && bigCollections.has(collection) ? big : normal;
    return parser(req, res, next);
  };
}
