import { useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthContext.tsx';
import { catalogMovies, catalogByGenre, catalogByDecade } from '../baas/services.ts';
import { watchedSet } from '../baas/watch.ts';
import type { Movie } from '../baas/types.ts';
import type { MessageKey } from '../i18n/dictionary.ts';

export type CategoryRow = { key: MessageKey; movies: Movie[] };

export type CatalogState = {
  hero: Movie | null;
  popular: Movie[];
  rows: CategoryRow[];
  watched: Set<string>;
  loading: boolean;
};

type Loader = { key: MessageKey; load: () => Promise<Movie[]> };

/** dedupeByCover keeps only the first cover-bearing film per id so a row never
 *  renders a card whose <img> would 404 (zero-console-error discipline). */
function dedupeByCover(movies: Movie[]): Movie[] {
  return movies.filter((m) => !!m.cover);
}

/** buildLoaders names the curated category rows ("Sci-Fi & Horror", decades…). */
function buildLoaders(cfg: ReturnType<typeof useAuth>['cfg']): Loader[] {
  return [
    { key: 'library.scifiHorror', load: () => catalogByGenre(cfg, 'Science Fiction') },
    { key: 'library.comedy', load: () => catalogByGenre(cfg, 'Comedy') },
    { key: 'library.silent', load: () => catalogByDecade(cfg, 1895, 1929) },
    { key: 'library.classics', load: () => catalogByDecade(cfg, 1930, 1969) },
  ];
}

/** useCatalog loads the cinematic home: a hero film, a popular row, and curated
 *  category rows, each fetch independently caught so one empty row never breaks
 *  the page or logs an error. */
export function useCatalog(): CatalogState {
  const { cfg } = useAuth();
  const [state, setState] = useState<CatalogState>({ hero: null, popular: [], rows: [], watched: new Set(), loading: true });

  useEffect(() => {
    let alive = true;
    setState((s) => ({ ...s, loading: true }));
    const work = Promise.all([
      catalogMovies(cfg, 0).then((r) => dedupeByCover(r.movies)).catch(() => [] as Movie[]),
      watchedSet(cfg).catch(() => new Set<string>()),
      Promise.all(buildLoaders(cfg).map((l) => l.load().then(dedupeByCover).catch(() => [] as Movie[]))),
    ]);
    work.then(([popular, watched, rowMovies]) => {
      if (!alive) return;
      const rows = buildLoaders(cfg)
        .map((l, i) => ({ key: l.key, movies: rowMovies[i] ?? [] }))
        .filter((r) => r.movies.length > 0);
      setState({ hero: popular[0] ?? null, popular: popular.slice(1), rows, watched, loading: false });
    });
    return () => {
      alive = false;
    };
  }, [cfg]);

  return state;
}
