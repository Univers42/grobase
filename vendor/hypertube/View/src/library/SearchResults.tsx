import { useI18n } from '../i18n/I18nContext.tsx';
import { useMovieSearch } from './useMovieSearch.ts';
import { useInfiniteScroll } from './useInfiniteScroll.ts';
import { MovieCard } from './MovieCard.tsx';
import { GridSkeleton } from './Skeleton.tsx';
import type { SearchSort } from '../baas/services.ts';

type Props = { query: string; sort: SearchSort; genre: string };

/** SearchResults renders the responsive infinite-scroll grid for an active
 *  query, with a shimmer grid on the first load and an empty state when none. */
export function SearchResults({ query, sort, genre }: Props) {
  const { t } = useI18n();
  const { movies, watched, loading, hasMore, loadMore } = useMovieSearch(query, sort, genre);
  const sentinel = useInfiniteScroll(loadMore, hasMore);
  const firstLoad = loading && movies.length === 0;

  return (
    <section className="search-results">
      <h2 className="library-heading">{t('library.results')}</h2>
      {firstLoad ? (
        <GridSkeleton />
      ) : (
        <div className="movie-grid">
          {movies.map((m) => (
            <MovieCard key={m.id} movie={m} watched={watched.has(m.id)} />
          ))}
        </div>
      )}
      {!loading && movies.length === 0 && <p className="empty">{t('library.empty')}</p>}
      <div ref={sentinel} className="scroll-sentinel" aria-hidden="true" />
    </section>
  );
}
