import { MovieCard } from './MovieCard.tsx';
import type { Movie } from '../baas/types.ts';

type Props = { title: string; movies: Movie[]; watched: Set<string> };

/** MovieRow renders a titled, horizontally snap-scrollable strip of cards. */
export function MovieRow({ title, movies, watched }: Props) {
  if (movies.length === 0) return null;
  return (
    <section className="movie-row">
      <h2 className="row-heading">{title}</h2>
      <div className="movie-strip" role="list">
        {movies.map((m) => (
          <div className="strip-item" role="listitem" key={m.id}>
            <MovieCard movie={m} watched={watched.has(m.id)} variant="row" />
          </div>
        ))}
      </div>
    </section>
  );
}
