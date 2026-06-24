import { useState } from 'react';
import { useI18n } from '../i18n/I18nContext.tsx';
import { LibraryHome } from '../library/LibraryHome.tsx';
import { SearchResults } from '../library/SearchResults.tsx';
import type { SearchSort } from '../baas/services.ts';

const SORTS: { value: SearchSort; key: 'library.sortName' | 'library.sortGenre' | 'library.sortRating' | 'library.sortYear' }[] = [
  { value: 'rating', key: 'library.sortRating' },
  { value: 'name', key: 'library.sortName' },
  { value: 'year', key: 'library.sortYear' },
  { value: 'genre', key: 'library.sortGenre' },
];

/** Library is the home surface: a search bar over either the cinematic default
 *  (hero + category rows) or, once a query is typed, the infinite results grid. */
export function Library() {
  const { t } = useI18n();
  const [query, setQuery] = useState('');
  const [genre, setGenre] = useState('');
  const [sort, setSort] = useState<SearchSort>('rating');
  const searching = query.trim().length > 0;

  return (
    <section className="library">
      <div className="library-bar">
        <div className="search-field">
          <span className="search-icon" aria-hidden="true">⌕</span>
          <input
            type="search"
            aria-label={t('library.search')}
            placeholder={t('library.search')}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          {searching && (
            <button type="button" className="link-button clear-btn" onClick={() => setQuery('')}>
              {t('library.clear')}
            </button>
          )}
        </div>
        {searching && (
          <div className="search-filters">
            <input
              type="text"
              aria-label={t('library.sortGenre')}
              placeholder={t('library.sortGenre')}
              value={genre}
              onChange={(e) => setGenre(e.target.value)}
            />
            <label className="sort-select">
              {t('library.sort')}
              <select aria-label={t('library.sort')} value={sort} onChange={(e) => setSort(e.target.value as SearchSort)}>
                {SORTS.map((s) => (
                  <option key={s.value} value={s.value}>{t(s.key)}</option>
                ))}
              </select>
            </label>
          </div>
        )}
      </div>
      {searching ? <SearchResults query={query} sort={sort} genre={genre} /> : <LibraryHome />}
    </section>
  );
}
