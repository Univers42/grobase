import { useCallback, useRef } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext.tsx';
import { useI18n } from '../i18n/I18nContext.tsx';
import { useMovieStream } from '../movie/useMovieStream.ts';
import { useRelated } from '../movie/useRelated.ts';
import { VideoPlayer } from '../movie/VideoPlayer.tsx';
import { MovieMeta } from '../movie/MovieMeta.tsx';
import { Comments } from '../movie/Comments.tsx';
import { MovieRow } from '../library/MovieRow.tsx';
import { markWatched } from '../baas/watch.ts';

/** Movie is the watch page: a large click-to-play player with the title, meta
 *  strip, expandable description, cast, a live comments panel, and a related
 *  row — YouTube-style two columns on desktop, stacked on mobile. The first
 *  play marks the film watched (once). */
export function Movie() {
  const { id = '' } = useParams();
  const { cfg } = useAuth();
  const { t } = useI18n();
  const { detail, subtitles, ready, error } = useMovieStream(id);
  const { related, watched } = useRelated(detail);
  const marked = useRef(false);

  const onPlay = useCallback(
    (currentTime: number) => {
      if (marked.current) return;
      marked.current = true;
      markWatched(cfg, id, currentTime).catch(() => undefined);
    },
    [cfg, id],
  );

  if (error) return <p className="empty">{t('common.error')}</p>;
  if (!ready || !detail) {
    return (
      <div className="watch">
        <div className="watch-main">
          <div className="video-wrap skeleton-block" />
        </div>
      </div>
    );
  }

  return (
    <div className="watch">
      <Link to="/library" className="back-link">← {t('movie.back')}</Link>
      <div className="watch-grid">
        <div className="watch-main">
          <VideoPlayer movieId={id} subtitles={subtitles} onPlay={onPlay} />
          <MovieMeta detail={detail} />
        </div>
        <aside className="watch-side">
          <Comments movieId={id} />
        </aside>
      </div>
      <MovieRow title={t('movie.related')} movies={related} watched={watched} />
    </div>
  );
}
