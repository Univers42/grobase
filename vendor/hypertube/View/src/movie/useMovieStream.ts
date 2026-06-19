import { useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthContext.tsx';
import { movieDetail, movieSubtitles } from '../baas/services.ts';
import type { MovieDetail, Subtitle } from '../baas/types.ts';

export type StreamState = {
  detail: MovieDetail | null;
  subtitles: Subtitle[];
  ready: boolean;
  error: string;
};

/** useMovieStream loads movie metadata + subtitles and asks the media service to
 *  ensure the torrent download has started, surfacing a ready/error flag. */
export function useMovieStream(id: string): StreamState {
  const { cfg } = useAuth();
  const [detail, setDetail] = useState<MovieDetail | null>(null);
  const [subtitles, setSubtitles] = useState<Subtitle[]>([]);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    let alive = true;
    setReady(false);
    setError('');
    Promise.all([movieDetail(cfg, id), movieSubtitles(cfg, id).catch(() => [])])
      .then(([d, subs]) => {
        if (!alive) return;
        setDetail(d);
        setSubtitles(subs);
        setReady(true);
      })
      .catch(() => alive && setError('unavailable'));
    return () => {
      alive = false;
    };
  }, [cfg, id]);

  return { detail, subtitles, ready, error };
}
