import { Logger } from '@nestjs/common';
import { resolveRequestIdentity } from '@mini-baas/common';
import { json, type Request, type RequestHandler } from 'express';

// The JSON body cap is per collection: every collection keeps the 100 KB default, and only
// the ones named in MONGO_API_BIG_COLLECTIONS (a whiteboard scene is one document of up to
// a few MB) take the larger limit. Empty by default, so nothing changes until an operator
// names a collection. The big limit also needs a verified caller: the parser runs before
// the route's AuthGuard, and an anonymous 8 MB parse costs ~57 MB of heap.

const COLLECTION_NAME = /^[\w-]{1,64}$/;
const DOCUMENTS_PATH = /^\/collections\/([^/]{1,192})\/documents(?:\/|$)/i;

export const DEFAULT_JSON_LIMIT = '100kb';
export const DEFAULT_BIG_JSON_LIMIT = '8mb';

export interface BigCollections {
  names: ReadonlySet<string>;
  rejected: string[];
}

/** The collection names in a comma-separated list, and the malformed ones left out. */
export function parseBigCollections(raw: string | undefined): BigCollections {
  const names = (raw ?? '')
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean);
  return {
    names: new Set(names.filter((name) => COLLECTION_NAME.test(name))),
    rejected: names.filter((name) => !COLLECTION_NAME.test(name)),
  };
}

/** The configured big limit, or the default when it is unset, empty or not a size. */
export function bigJsonLimit(raw: string | undefined): string {
  const limit = raw?.trim();
  if (!limit) return DEFAULT_BIG_JSON_LIMIT;
  try {
    json({ limit });
    return limit;
  } catch {
    Logger.warn(
      `MONGO_API_BIG_JSON_LIMIT "${limit}" is not a size; using ${DEFAULT_BIG_JSON_LIMIT}`,
      'BodyLimits',
    );
    return DEFAULT_BIG_JSON_LIMIT;
  }
}

/**
 * The collection a documents route addresses, decoded the way Express decodes the route
 * param, or null for any other path. Express matches routes case-insensitively, so the
 * prefix does too.
 */
export function documentsCollection(path: string): string | null {
  const segment = DOCUMENTS_PATH.exec(path)?.[1];
  if (segment === undefined) return null;
  try {
    const name = decodeURIComponent(segment);
    return COLLECTION_NAME.test(name) ? name : null;
  } catch {
    return null;
  }
}

// Caveat: a peek, not the check. It skips the nonce record (AuthGuard records it, and a
// second record would read as a replay), so a replayed envelope inside its freshness
// window still earns one big parse before AuthGuard refuses it.
const PEEK_NONCES = { remember: () => true };

/** True when the request carries an identity AuthGuard would accept. */
export function hasVerifiedIdentity(req: Request): Promise<boolean> {
  return resolveRequestIdentity(req, false, PEEK_NONCES).then(Boolean, () => false);
}

/** One JSON parser for the whole app that picks the limit by the addressed collection. */
export function jsonBodyParser(
  bigCollections: ReadonlySet<string>,
  bigLimit: string,
  isVerified: (req: Request) => Promise<boolean> = hasVerifiedIdentity,
): RequestHandler {
  const normal = json({ limit: DEFAULT_JSON_LIMIT });
  const big = json({ limit: bigLimit });
  return (req, res, next) => {
    const collection = documentsCollection(req.path);
    if (collection === null || !bigCollections.has(collection)) return normal(req, res, next);
    isVerified(req).then(
      (verified) => (verified ? big : normal)(req, res, next),
      () => normal(req, res, next),
    );
  };
}
