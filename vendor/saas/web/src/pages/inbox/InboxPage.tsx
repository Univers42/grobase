// InboxPage.tsx — the inbox section: a premium glass master-detail. The left pane
// lists active messages (filterable All/Open/Closed) with an unread count in the
// header; the right pane reads the selected message and runs its lifecycle actions.

import { useMemo, useState } from 'react';
import { GlassCard } from '../../ds/GlassCard';
import { Badge } from '../../ds/Badge';
import { Spinner } from '../../ds/Spinner';
import { EmptyState } from '../../ds/EmptyState';
import { useMessages } from './useMessages';
import { MessageList } from './MessageList';
import { MessageView } from './MessageView';
import { InboxFilterTabs } from './InboxFilterTabs';
import type { InboxFilter } from './InboxFilterTabs';

/** matchesFilter keeps a message when the active folder accepts its status. */
function matchesFilter(status: string, filter: InboxFilter): boolean {
  return filter === 'all' || status === filter;
}

/** InboxPage renders the filterable, master-detail inbox over Mongo `messages`. */
export function InboxPage() {
  const { messages, unread, loading, error, refetch, markRead, setStatus } = useMessages();
  const [filter, setFilter] = useState<InboxFilter>('all');
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const visible = useMemo(() => messages.filter((m) => matchesFilter(m.status, filter)), [messages, filter]);
  const selected = useMemo(() => messages.find((m) => m.id === selectedId) ?? null, [messages, selectedId]);

  return (
    <section className="space-y-5">
      <header className="flex items-end justify-between gap-4">
        <div>
          <h1 className="flex items-center gap-2.5 text-2xl font-semibold tracking-tight text-ink">
            Inbox
            {unread > 0 && <Badge tone="accent">{unread} unread</Badge>}
          </h1>
          <p className="mt-1 text-sm text-muted">Messages and activity across your workspace.</p>
        </div>
        <InboxFilterTabs value={filter} onChange={setFilter} />
      </header>

      {error && (
        <GlassCard>
          <EmptyState icon="alert" title="Couldn’t load messages" description={error} />
        </GlassCard>
      )}

      <div className="grid gap-4 lg:grid-cols-[minmax(0,22rem)_1fr]">
        <GlassCard className="flex max-h-[70vh] min-h-[24rem] flex-col p-3">
          {loading && messages.length === 0 ? (
            <div className="grid flex-1 place-items-center"><Spinner label="Loading messages" /></div>
          ) : visible.length === 0 ? (
            <div className="grid flex-1 place-items-center">
              <EmptyState icon="inbox" title="No messages here" description="This folder is empty." />
            </div>
          ) : (
            <MessageList messages={visible} selectedId={selectedId} onSelect={setSelectedId} />
          )}
        </GlassCard>

        <GlassCard className="max-h-[70vh] min-h-[24rem] overflow-hidden">
          <MessageView
            message={selected}
            onRead={async (id) => { await markRead(id); refetch(); }}
            onStatus={async (id, status) => { await setStatus(id, status); setSelectedId(null); }}
          />
        </GlassCard>
      </div>
    </section>
  );
}
