import { useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthContext.tsx';
import { relatedMovies } from '../baas/services.ts';
import { watchedSet } from '../baas/watch.ts';
import type { Movie, MovieDetail } from '../baas/types.ts';

export type RelatedState = { related: Movie[]; watched: Set<string> };

/** useRelated loads the "More like this" row for a film, every fetch caught so
 *  an empty related set never breaks the watch page or logs an error. */
export function useRelated(detail: MovieDetail | null): RelatedState {
  const { cfg } = useAuth();
  const [state, setState] = useState<RelatedState>({ related: [], watched: new Set() });

  useEffect(() => {
    if (!detail) return;
    let alive = true;
    Promise.all([
      relatedMovies(cfg, detail).catch(() => [] as Movie[]),
      watchedSet(cfg).catch(() => new Set<string>()),
    ]).then(([related, watched]) => {
      if (alive) setState({ related: related.filter((m) => !!m.cover), watched });
    });
    return () => {
      alive = false;
    };
  }, [cfg, detail]);

  return state;
}
