// MessageList.tsx — the left master pane: a scrollable column of message rows. Each
// row shows the sender avatar, an unread dot, subject, a one-line snippet, and a
// relative timestamp. Selecting a row lifts its id to the parent.

import clsx from 'clsx';
import { Avatar } from '../../ds/Avatar';
import type { Message } from './message';
import { snippet, relativeTime } from './message';

/** MessageListProps wires the rows, the current selection, and the select handler. */
export type MessageListProps = {
  messages: Message[];
  selectedId: string | null;
  onSelect: (id: string) => void;
};

/** MessageRow renders one selectable message line in the list. */
function MessageRow({ message, active, onSelect }: { message: Message; active: boolean; onSelect: (id: string) => void }) {
  return (
    <button
      type="button"
      onClick={() => onSelect(message.id)}
      aria-current={active || undefined}
      className={clsx(
        'flex w-full items-start gap-3 rounded-xl px-3 py-3 text-left transition',
        active ? 'bg-accent-soft ring-1 ring-accent/30' : 'hover:bg-white/5',
      )}
    >
      <Avatar name={message.from} size={36} />
      <span className="min-w-0 flex-1">
        <span className="flex items-center justify-between gap-2">
          <span className={clsx('truncate text-sm', message.read ? 'text-muted' : 'font-semibold text-ink')}>
            {message.from}
          </span>
          <span className="shrink-0 text-xs text-muted">{relativeTime(message.createdAt)}</span>
        </span>
        <span className={clsx('block truncate text-sm', message.read ? 'text-muted' : 'text-ink')}>
          {message.subject}
        </span>
        <span className="mt-0.5 block truncate text-xs text-muted">{snippet(message.body)}</span>
      </span>
      {!message.read && <span className="mt-1.5 size-2 shrink-0 rounded-full bg-accent" aria-label="unread" />}
    </button>
  );
}

/** MessageList renders the master column of message rows. */
export function MessageList({ messages, selectedId, onSelect }: MessageListProps) {
  return (
    <div className="flex flex-col gap-1 overflow-y-auto pr-1">
      {messages.map((m) => (
        <MessageRow key={m.id} message={m} active={m.id === selectedId} onSelect={onSelect} />
      ))}
    </div>
  );
}
