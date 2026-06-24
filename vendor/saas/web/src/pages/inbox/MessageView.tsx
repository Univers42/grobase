// MessageView.tsx — the right detail pane: header (sender, subject, status, time),
// tags, and the message body. Opening a message marks it read once. An EmptyState
// stands in when nothing is selected.

import { useEffect } from 'react';
import { Avatar } from '../../ds/Avatar';
import { Badge } from '../../ds/Badge';
import type { BadgeTone } from '../../ds/Badge';
import { EmptyState } from '../../ds/EmptyState';
import { MessageActions } from './MessageActions';
import type { Message, MessageStatus } from './message';
import { relativeTime } from './message';

/** MessageViewProps wires the selected message and the read/status mutations. */
export type MessageViewProps = {
  message: Message | null;
  onRead: (id: string) => Promise<void>;
  onStatus: (id: string, status: MessageStatus) => Promise<void>;
};

const statusTone: Record<MessageStatus, BadgeTone> = { open: 'accent', closed: 'success', archived: 'neutral' };

/** MessageView renders the reading pane and marks the message read on open. */
export function MessageView({ message, onRead, onStatus }: MessageViewProps) {
  useEffect(() => {
    if (message && !message.read) void onRead(message.id);
  }, [message, onRead]);

  if (!message) {
    return <EmptyState icon="inbox" title="No message selected" description="Pick a conversation from the list to read it." />;
  }

  return (
    <article className="flex h-full flex-col gap-5">
      <header className="flex items-start justify-between gap-4 border-b border-line pb-4">
        <div className="flex items-start gap-3">
          <Avatar name={message.from} size={44} />
          <div className="min-w-0">
            <h2 className="truncate text-lg font-semibold text-ink">{message.subject}</h2>
            <p className="truncate text-sm text-muted">{message.from}</p>
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <Badge tone={statusTone[message.status]}>{message.status}</Badge>
          <span className="text-xs text-muted">{relativeTime(message.createdAt)}</span>
        </div>
      </header>

      {message.tags.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {message.tags.map((t) => (
            <Badge key={t} tone="neutral">{t}</Badge>
          ))}
        </div>
      )}

      <p className="flex-1 overflow-y-auto whitespace-pre-wrap text-sm leading-relaxed text-ink/90">{message.body}</p>

      <footer className="border-t border-line pt-4">
        <MessageActions message={message} onStatus={onStatus} />
      </footer>
    </article>
  );
}
