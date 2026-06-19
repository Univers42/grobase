import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthContext.tsx';
import { listComments, postComment } from '../baas/content.ts';
import { commentsTopic, subscribeTable } from '../baas/realtime.ts';
import type { Comment } from '../baas/types.ts';

export type CommentsState = {
  comments: Comment[];
  submit: (authorId: string, authorUsername: string, content: string) => Promise<void>;
};

/** isForMovie tests whether a realtime payload row belongs to this movie. */
function isForMovie(payload: unknown, movieId: string): boolean {
  const row = (payload as { row?: { movie_id?: string }; data?: { movie_id?: string } }) ?? {};
  return (row.row?.movie_id ?? row.data?.movie_id) === movieId;
}

/** useComments loads a movie's comments and keeps them live over realtime. */
export function useComments(movieId: string): CommentsState {
  const { cfg } = useAuth();
  const [comments, setComments] = useState<Comment[]>([]);

  const refresh = useCallback(() => {
    listComments(cfg, movieId).then(setComments).catch(() => undefined);
  }, [cfg, movieId]);

  useEffect(() => {
    refresh();
    const handle = subscribeTable(cfg, commentsTopic(cfg), (payload) => {
      if (isForMovie(payload, movieId)) refresh();
    });
    return () => handle.close();
  }, [cfg, movieId, refresh]);

  const submit = useCallback(
    async (authorId: string, authorUsername: string, content: string) => {
      await postComment(cfg, movieId, authorId, authorUsername, content);
      refresh();
    },
    [cfg, movieId, refresh],
  );

  return { comments, submit };
}
