/** CardSkeleton renders one shimmer placeholder shaped like a movie card. */
export function CardSkeleton({ variant = 'grid' }: { variant?: 'grid' | 'row' }) {
  return (
    <div className={`movie-card movie-card--${variant} is-skeleton`} aria-hidden="true">
      <div className="movie-cover skeleton-block" />
      <div className="skeleton-line skeleton-line--title" />
      <div className="skeleton-line skeleton-line--meta" />
    </div>
  );
}

/** RowSkeleton renders a horizontal strip of card skeletons for a loading row. */
export function RowSkeleton({ count = 6 }: { count?: number }) {
  return (
    <div className="movie-strip" aria-hidden="true">
      {Array.from({ length: count }, (_, i) => (
        <CardSkeleton key={i} variant="row" />
      ))}
    </div>
  );
}

/** GridSkeleton renders a grid of card skeletons for a loading search/grid view. */
export function GridSkeleton({ count = 12 }: { count?: number }) {
  return (
    <div className="movie-grid" aria-hidden="true">
      {Array.from({ length: count }, (_, i) => (
        <CardSkeleton key={i} />
      ))}
    </div>
  );
}
