import { useState, type FormEvent } from 'react';
import { useAuth } from '../auth/AuthContext.tsx';
import { useI18n } from '../i18n/I18nContext.tsx';
import { useComments } from './useComments.ts';
import { jwtDisplayName } from '../baas/session.ts';

/** Comments renders the live comment list and the post box for a movie. */
export function Comments({ movieId }: { movieId: string }) {
  const { session } = useAuth();
  const { t } = useI18n();
  const { comments, submit } = useComments(movieId);
  const [body, setBody] = useState('');

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    const text = body.trim();
    if (!text || !session) return;
    setBody('');
    await submit(session.userId, jwtDisplayName(session.accessToken), text);
  };

  return (
    <section className="comments">
      <h2>{t('movie.comments')}</h2>
      <form onSubmit={onSubmit} className="comment-form">
        <textarea
          aria-label={t('movie.commentPlaceholder')}
          placeholder={t('movie.commentPlaceholder')}
          value={body}
          maxLength={2000}
          onChange={(e) => setBody(e.target.value)}
        />
        <button type="submit" disabled={!body.trim()}>{t('movie.postComment')}</button>
      </form>
      {comments.length === 0 && <p className="comments-empty">{t('movie.noComments')}</p>}
      <ul className="comment-list" data-testid="comment-list">
        {comments.map((c) => (
          <li key={c.id} className="comment-item">
            <span className="comment-author">{c.author_username}</span>
            <p className="comment-body">{c.content}</p>
            <time className="comment-time">{new Date(c.created_at).toLocaleString()}</time>
          </li>
        ))}
      </ul>
    </section>
  );
}
