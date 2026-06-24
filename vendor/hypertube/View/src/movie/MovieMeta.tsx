import { useState } from 'react';
import { useI18n } from '../i18n/I18nContext.tsx';
import type { MovieDetail } from '../baas/types.ts';
import { formatDuration, ratingLabel } from '../library/format.ts';

const CLAMP = 320;

/** MovieMeta renders the title, the meta strip (year · duration · ★ · genres),
 *  an expandable description, and the cast panel for the watch page. */
export function MovieMeta({ detail }: { detail: MovieDetail }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const long = detail.summary.length > CLAMP;
  const text = open || !long ? detail.summary : `${detail.summary.slice(0, CLAMP)}…`;
  const duration = formatDuration(detail.runtime);

  return (
    <div className="movie-info">
      <h1 className="movie-headline">{detail.title}</h1>
      <div className="meta-strip">
        {detail.year && <span>{detail.year}</span>}
        {duration && <span>{duration}</span>}
        <span className="star">★ {ratingLabel(detail.rating)}</span>
        <span className="genre-chips">
          {detail.genres.map((g) => (
            <span key={g} className="genre-chip">{g}</span>
          ))}
        </span>
      </div>
      {detail.summary && (
        <div className="movie-description">
          <h2>{t('movie.summary')}</h2>
          <p>{text}</p>
          {long && (
            <button type="button" className="link-button" onClick={() => setOpen((v) => !v)}>
              {open ? t('movie.showLess') : t('movie.showMore')}
            </button>
          )}
        </div>
      )}
      <div className="movie-cast">
        <h2>{t('movie.cast')}</h2>
        <ul className="cast-list">
          {detail.cast?.director && <li><span className="cast-role">{t('movie.director')}</span> {detail.cast.director}</li>}
          {detail.cast?.producer && <li><span className="cast-role">{t('movie.producer')}</span> {detail.cast.producer}</li>}
          {(detail.cast?.main ?? []).map((person) => (
            <li key={person}>{person}</li>
          ))}
        </ul>
      </div>
    </div>
  );
}
