// useMessages.ts — owns the inbox data: lists active messages (status != archived,
// newest first), exposes the unread count, and the read/close/archive/reopen
// mutations. Centralizing the db.mongo calls keeps the components presentational
// and avoids drilling the client past two levels.

import { useCallback, useEffect, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import type { Message, MessageStatus } from './message';
import { parseMessage } from './message';

/** MessagesState is the reactive inbox snapshot plus its mutations. */
export type MessagesState = {
  messages: Message[];
  unread: number;
  loading: boolean;
  error: string | null;
  refetch: () => void;
  markRead: (id: string) => Promise<void>;
  setStatus: (id: string, status: MessageStatus) => Promise<void>;
};

/** useMessages lists active inbox messages and exposes their lifecycle mutations. */
export function useMessages(): MessagesState {
  const { db } = useBaas();
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    db.mongo
      .listAll('messages', { filter: { status: { $ne: 'archived' } }, sort: { created_at: 'desc' } })
      .then((rows) => !cancelled && setMessages(rows.map(parseMessage)))
      .catch((e: unknown) => !cancelled && setError(e instanceof Error ? e.message : 'failed to load messages'))
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [db, tick]);

  const refetch = useCallback(() => setTick((t) => t + 1), []);

  const markRead = useCallback(
    async (id: string) => {
      await db.mongo.update('messages', { read: true }, { _id: id });
      setMessages((prev) => prev.map((m) => (m.id === id ? { ...m, read: true } : m)));
    },
    [db],
  );

  const setStatus = useCallback(
    async (id: string, status: MessageStatus) => {
      await db.mongo.update('messages', { status }, { _id: id });
      refetch();
    },
    [db, refetch],
  );

  const unread = messages.filter((m) => !m.read).length;
  return { messages, unread, loading, error, refetch, markRead, setStatus };
}
