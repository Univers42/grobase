import { useI18n } from '../i18n/I18nContext.tsx';
import { useCatalog } from './useCatalog.ts';
import { Hero } from './Hero.tsx';
import { MovieRow } from './MovieRow.tsx';
import { RowSkeleton } from './Skeleton.tsx';

/** LibraryHome is the cinematic default view: a featured hero, a Popular row,
 *  and curated category rows. Shimmer skeletons fill the rows while loading so
 *  there is no layout shift. */
export function LibraryHome() {
  const { t } = useI18n();
  const { hero, popular, rows, watched, loading } = useCatalog();

  if (loading) {
    return (
      <div className="home">
        <div className="hero hero--skeleton skeleton-block" />
        <section className="movie-row">
          <h2 className="row-heading">{t('library.popular')}</h2>
          <RowSkeleton />
        </section>
      </div>
    );
  }

  return (
    <div className="home">
      {hero && <Hero movie={hero} watched={watched.has(hero.id)} />}
      <MovieRow title={t('library.popular')} movies={popular} watched={watched} />
      {rows.map((r) => (
        <MovieRow key={r.key} title={t(r.key)} movies={r.movies} watched={watched} />
      ))}
    </div>
  );
}
