import { useState } from 'react';
import { useAuth } from '../auth/AuthContext.tsx';
import { streamSrc } from '../baas/services.ts';
import type { Subtitle } from '../baas/types.ts';

type Props = {
  movieId: string;
  subtitles: Subtitle[];
  onPlay: (currentTime: number) => void;
};

/** VideoPlayer shows a click-to-play poster, then loads the same-origin stream
 *  (apikey in the query string so the gateway authorizes the <video> GET that
 *  cannot send headers). The stream is lazy: nothing is fetched until the user
 *  presses play, so a not-yet-downloaded torrent never errors on the library. */
export function VideoPlayer({ movieId, subtitles, onPlay }: Props) {
  const { cfg } = useAuth();
  const [started, setStarted] = useState(false);
  const src = started ? `${streamSrc(movieId)}?apikey=${encodeURIComponent(cfg.anonKey)}` : undefined;

  return (
    <div className="video-wrap">
      <video
        className="video-player"
        controls
        preload="none"
        data-testid="video-player"
        src={src}
        autoPlay={started}
        onPlay={(e) => onPlay(e.currentTarget.currentTime)}
      >
        {started &&
          subtitles.map((s) => (
            <track key={s.lang} kind="subtitles" src={s.url} srcLang={s.lang} label={s.label} default={s.lang === 'en'} />
          ))}
      </video>
      {!started && (
        <button type="button" className="video-play" aria-label="Play" onClick={() => setStarted(true)}>
          <span className="video-play-icon" aria-hidden="true">▶</span>
        </button>
      )}
    </div>
  );
}
