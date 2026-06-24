import type { BaasConfig } from './config.ts';
import { baseHeaders, requestJson } from './http.ts';
import { listRows } from './query.ts';
import type { Movie, MovieDetail, StreamStatus, Subtitle } from './types.ts';

export type SearchSort = 'name' | 'genre' | 'rating' | 'year';

export type SearchParams = {
  q: string;
  sort: SearchSort;
  genre?: string;
  page: number;
};

/** One raw row from the hypertube-search service (archive.org + TMDb). */
type RawResult = {
  movieId: string;
  title: string;
  year?: number;
  coverUrl?: string;
  downloads?: number;
  metadata?: { rating?: number | null; genres?: string[]; summary?: string };
};
type RawSearch = { results?: RawResult[]; count?: number; page?: number };

/** A movie document as stored in the Mongo `movies` catalog. */
type RawMovie = {
  movie_id: string;
  title?: string;
  year?: number;
  rating?: number | null;
  cover_url?: string;
  genres?: string[];
  summary?: string;
  length_min?: number | null;
  cast?: { role?: string; name?: string }[];
};

/** toMovie maps a search row to the UI Movie shape (year 0 → null). */
function toMovie(r: RawResult): Movie {
  return {
    id: r.movieId,
    title: r.title ?? '',
    year: r.year && r.year > 0 ? r.year : null,
    rating: r.metadata?.rating ?? null,
    cover: r.coverUrl ?? null,
    genres: r.metadata?.genres ?? [],
  };
}

/** searchMovies queries the custom search service and normalizes its
 *  `{results}` envelope into the UI `{movies, hasMore}` shape. */
export async function searchMovies(cfg: BaasConfig, p: SearchParams): Promise<{ movies: Movie[]; hasMore: boolean }> {
  const qs = new URLSearchParams({ q: p.q, sort: p.sort, page: String(p.page) });
  if (p.genre) qs.set('genre', p.genre);
  const raw = await requestJson<RawSearch>('/search/v1/search?' + qs.toString(), {
    method: 'GET',
    headers: baseHeaders(cfg, false),
  });
  const results = raw.results ?? [];
  return { movies: results.map(toMovie), hasMore: results.length >= 20 };
}

/** catalogMovies reads the curated, cover-validated catalog (Mongo movies) sorted
 *  by popularity — the default library view (no search query), via the shared
 *  public path. Live archive.org search is reserved for an explicit query. */
export async function catalogMovies(cfg: BaasConfig, page: number): Promise<{ movies: Movie[]; hasMore: boolean }> {
  const rows = await listRows<RawMovie>(cfg, cfg.mongoDbId, 'movies', { sort: { popularity: 'desc' }, limit: 30, offset: page * 30 }, { shared: true });
  return { movies: mapRows(rows), hasMore: rows.length >= 30 };
}

/** toDetail shapes a Mongo movie document into the video page's MovieDetail. */
function toDetail(m: RawMovie): MovieDetail {
  const cast = Array.isArray(m.cast) ? m.cast : [];
  const role = (r: string) => cast.find((c) => (c.role ?? '').toLowerCase() === r)?.name ?? null;
  const main = cast.filter((c) => !['director', 'producer'].includes((c.role ?? '').toLowerCase())).map((c) => c.name ?? '');
  return {
    id: m.movie_id,
    title: m.title ?? '',
    year: m.year && m.year > 0 ? m.year : null,
    rating: m.rating ?? null,
    cover: m.cover_url ?? null,
    genres: Array.isArray(m.genres) ? m.genres : [],
    summary: m.summary ?? '',
    runtime: m.length_min ?? null,
    cast: { director: role('director'), producer: role('producer'), main: main.filter(Boolean) },
  };
}

/** movieDetail reads the enriched movie from the shared Mongo catalog. */
export async function movieDetail(cfg: BaasConfig, id: string): Promise<MovieDetail> {
  const rows = await listRows<RawMovie>(cfg, cfg.mongoDbId, 'movies', { filter: { movie_id: { $eq: id } }, limit: 1 }, { shared: true });
  const m = rows[0];
  if (!m) throw { status: 404, message: 'movie not found' };
  return toDetail(m);
}

/** ensureStream asks the media service to start (or resume) a torrent download. */
export function ensureStream(cfg: BaasConfig, id: string): Promise<StreamStatus> {
  return requestJson(`/media/v1/movies/${encodeURIComponent(id)}/ensure`, { method: 'POST', headers: baseHeaders(cfg) });
}

/** streamStatus polls the media service for download/transcode progress. */
export function streamStatus(cfg: BaasConfig, id: string): Promise<StreamStatus> {
  return requestJson(`/media/v1/movies/${encodeURIComponent(id)}/status`, { method: 'GET', headers: baseHeaders(cfg) });
}

/** movieSubtitles returns the available subtitle tracks. The media service
 *  exposes per-lang tracks (/subtitles/{lang}.vtt), not a list, and OpenSubtitles
 *  is optional — so this degrades to none rather than firing a 404. */
export function movieSubtitles(_cfg: BaasConfig, _id: string): Promise<Subtitle[]> {
  return Promise.resolve([]);
}

/** streamSrc returns the same-origin <video> src for a movie's stream, served
 *  by the fast Rust /stream/v1 engine (not the slow /media/v1 torrent path). */
export function streamSrc(id: string): string {
  return `/stream/v1/movies/${encodeURIComponent(id)}`;
}

/** mapRows maps raw Mongo movie documents to the UI Movie shape. */
function mapRows(rows: RawMovie[]): Movie[] {
  return rows.map((m) => ({
    id: m.movie_id,
    title: m.title ?? '',
    year: m.year && m.year > 0 ? m.year : null,
    rating: m.rating ?? null,
    cover: m.cover_url ?? null,
    genres: Array.isArray(m.genres) ? m.genres : [],
    runtime: m.length_min ?? null,
    summary: m.summary ?? '',
  }));
}

/** catalogByGenre reads the top-popularity slice of one genre (shared path). */
export async function catalogByGenre(cfg: BaasConfig, genre: string, limit = 24): Promise<Movie[]> {
  const rows = await listRows<RawMovie>(cfg, cfg.mongoDbId, 'movies', { filter: { genres: { $eq: genre } }, sort: { popularity: 'desc' }, limit }, { shared: true });
  return mapRows(rows);
}

/** catalogByDecade reads films within a [from, to] year window (shared path). */
export async function catalogByDecade(cfg: BaasConfig, from: number, to: number, limit = 24): Promise<Movie[]> {
  const rows = await listRows<RawMovie>(cfg, cfg.mongoDbId, 'movies', { filter: { year: { $gte: from, $lte: to } }, sort: { popularity: 'desc' }, limit }, { shared: true });
  return mapRows(rows);
}

/** relatedMovies reads same-genre films for the "More like this" row, excluding
 *  the current film; falls back to popular when the film has no genre. */
export async function relatedMovies(cfg: BaasConfig, movie: MovieDetail, limit = 12): Promise<Movie[]> {
  const genre = movie.genres[0];
  const body = genre
    ? { filter: { genres: { $eq: genre } }, sort: { popularity: 'desc' as const }, limit: limit + 1 }
    : { sort: { popularity: 'desc' as const }, limit: limit + 1 };
  const rows = await listRows<RawMovie>(cfg, cfg.mongoDbId, 'movies', body, { shared: true });
  return mapRows(rows).filter((m) => m.id !== movie.id).slice(0, limit);
}
