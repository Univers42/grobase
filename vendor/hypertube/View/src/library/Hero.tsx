import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useI18n } from '../i18n/I18nContext.tsx';
import type { Movie } from '../baas/types.ts';
import { formatDuration, ratingLabel } from './format.ts';

/** Hero renders the cinematic featured film: backdrop, title, meta strip,
 *  summary, and Play + Details actions. A failed backdrop falls back to the
 *  gradient so no broken image is ever requested twice. */
export function Hero({ movie, watched }: { movie: Movie; watched: boolean }) {
  const { t } = useI18n();
  const navigate = useNavigate();
  const [broken, setBroken] = useState(false);
  const to = `/movie/${encodeURIComponent(movie.id)}`;
  const duration = formatDuration(movie.runtime);
  return (
    <section className={`hero${watched ? ' is-watched' : ''}`}>
      {movie.cover && !broken && (
        <img className="hero-backdrop" src={movie.cover} alt="" aria-hidden="true" onError={() => setBroken(true)} />
      )}
      <div className="hero-scrim" aria-hidden="true" />
      <div className="hero-content">
        <h1 className="hero-title">{movie.title}</h1>
        <p className="hero-meta">
          {movie.year && <span>{movie.year}</span>}
          <span className="star">★ {ratingLabel(movie.rating)}</span>
          {duration && <span>{duration}</span>}
          {movie.genres.slice(0, 2).map((g) => (
            <span key={g} className="hero-genre">{g}</span>
          ))}
        </p>
        {movie.summary && <p className="hero-summary">{movie.summary}</p>}
        <div className="hero-actions">
          <button type="button" className="btn-play" onClick={() => navigate(to)}>
            <span aria-hidden="true">▶</span> {t('library.play')}
          </button>
          <button type="button" className="btn-ghost" onClick={() => navigate(to)}>
            {t('library.details')}
          </button>
        </div>
      </div>
    </section>
  );
}
