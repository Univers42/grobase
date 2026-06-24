import { useCallback, useEffect, useRef, useState } from 'react';
import { useAuth } from '../auth/AuthContext.tsx';
import { searchMovies, catalogMovies, type SearchSort } from '../baas/services.ts';
import { watchedSet } from '../baas/watch.ts';
import type { Movie } from '../baas/types.ts';

export type SearchState = {
  movies: Movie[];
  watched: Set<string>;
  loading: boolean;
  hasMore: boolean;
  loadMore: () => void;
};

/** useMovieSearch fetches paginated movies for a query+sort+genre, exposing an
 *  append-only list and a loadMore() for IntersectionObserver-driven scroll. */
export function useMovieSearch(q: string, sort: SearchSort, genre: string): SearchState {
  const { cfg } = useAuth();
  const [movies, setMovies] = useState<Movie[]>([]);
  const [watched, setWatched] = useState<Set<string>>(new Set());
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const reqId = useRef(0);

  useEffect(() => {
    setMovies([]);
    setPage(0);
    setHasMore(true);
  }, [q, sort, genre]);

  useEffect(() => {
    watchedSet(cfg).then(setWatched).catch(() => undefined);
  }, [cfg]);

  useEffect(() => {
    const id = ++reqId.current;
    setLoading(true);
    const fetcher = q.trim() ? searchMovies(cfg, { q, sort, genre: genre || undefined, page }) : catalogMovies(cfg, page);
    fetcher
      .then((res) => {
        if (id !== reqId.current) return;
        setMovies((prev) => (page === 0 ? res.movies ?? [] : [...prev, ...(res.movies ?? [])]));
        setHasMore(res.hasMore);
      })
      .catch(() => id === reqId.current && setHasMore(false))
      .finally(() => id === reqId.current && setLoading(false));
  }, [cfg, q, sort, genre, page]);

  const loadMore = useCallback(() => {
    if (!loading && hasMore) setPage((p) => p + 1);
  }, [loading, hasMore]);

  return { movies, watched, loading, hasMore, loadMore };
}
