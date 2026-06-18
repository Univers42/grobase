// time/index.js — relative-time formatting. Pure: no baas/SDK import. Mirrors the
// PHP feed.php elapsed-time rendering ("Just now" / "5 minutes ago" / …) as a
// compact "just now"/"5m"/"3h"/"2d" string for the SPA cards.

/**
 * timeAgo turns an ISO-8601 timestamp into a short relative label. Returns
 * "just now" under a minute, then "<n>m", "<n>h", "<n>d", and falls back to a
 * locale date string beyond a week. Invalid input yields an empty string.
 * @param iso an ISO timestamp string (e.g. created_at)
 * @returns the short relative-time label
 */
export function timeAgo(iso) {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return '';
  const sec = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (sec < 60) return 'just now';
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  if (sec < 604800) return `${Math.floor(sec / 86400)}d`;
  return new Date(then).toLocaleDateString();
}

export const time = { timeAgo };
