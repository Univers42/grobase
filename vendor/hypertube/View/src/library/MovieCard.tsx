import { useState } from 'react';
import { Link } from 'react-router-dom';
import type { Movie } from '../baas/types.ts';
import { formatDuration, ratingLabel } from './format.ts';

type Props = { movie: Movie; watched: boolean; variant?: 'grid' | 'row' };

/** MovieCard renders one cinematic thumbnail: cover, hover play affordance,
 *  title (clamped), year · ★rating, a duration pill, and a watched ✓ badge.
 *  A cover that fails to load swaps to the gradient fallback (no broken image). */
export function MovieCard({ movie, watched, variant = 'grid' }: Props) {
  const [broken, setBroken] = useState(false);
  const duration = formatDuration(movie.runtime);
  return (
    <Link
      to={`/movie/${encodeURIComponent(movie.id)}`}
      className={`movie-card movie-card--${variant}${watched ? ' is-watched' : ''}`}
      data-testid="movie-card"
    >
      <div className="movie-cover">
        {movie.cover && !broken ? (
          <img src={movie.cover} alt={movie.title} loading="lazy" onError={() => setBroken(true)} />
        ) : (
          <div className="movie-cover-fallback" aria-hidden="true">
            <span>{movie.title.slice(0, 1) || '?'}</span>
          </div>
        )}
        <span className="movie-play-affordance" aria-hidden="true">▶</span>
        {watched && <span className="watch-tick" aria-label="watched">✓</span>}
        {duration && <span className="duration-pill">{duration}</span>}
      </div>
      <h3 className="movie-title">{movie.title}</h3>
      <p className="movie-meta">
        <span>{movie.year ?? '—'}</span>
        <span className="dot">·</span>
        <span className="star">★ {ratingLabel(movie.rating)}</span>
      </p>
    </Link>
  );
}
