/** formatDuration renders a minute count as "1h 42m" / "48m", or "" when null. */
export function formatDuration(min: number | null | undefined): string {
  if (!min || min <= 0) return '';
  const h = Math.floor(min / 60);
  const m = min % 60;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

/** ratingLabel renders a one-decimal star rating, or an em dash when unknown. */
export function ratingLabel(rating: number | null | undefined): string {
  return rating != null ? rating.toFixed(1) : '—';
}
