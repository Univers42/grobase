// ActivityFeed.tsx — the recent-activity panel: the latest workspace events from
// the Mongo `activity` mount, newest first. Pure presentation; the page supplies
// the already-narrowed items, the loading flag, and the error.

import { GlassCard } from '../../ds/GlassCard';
import { Avatar } from '../../ds/Avatar';
import { Spinner } from '../../ds/Spinner';
import { EmptyState } from '../../ds/EmptyState';
import type { ActivityItem } from './overview-data';
import { relativeTime } from './overview-data';

/** ActivityFeedProps supplies the feed items and its load/error state. */
export type ActivityFeedProps = { items: readonly ActivityItem[]; loading: boolean; error: string | null };

/** ActivityRow renders one event line: actor avatar, sentence, and a time label. */
function ActivityRow({ item }: { item: ActivityItem }) {
  return (
    <li className="flex items-center gap-3">
      <Avatar name={item.actor} size={32} />
      <p className="min-w-0 flex-1 truncate text-sm text-ink">
        <span className="font-medium">{item.actor}</span>{' '}
        <span className="text-muted">{item.action}</span>
        {item.target && <span className="text-ink"> {item.target}</span>}
      </p>
      <time className="shrink-0 text-xs text-muted tabular-nums">{relativeTime(item.at)}</time>
    </li>
  );
}

/** ActivityFeed renders the recent-activity list with loading/empty/error states. */
export function ActivityFeed({ items, loading, error }: ActivityFeedProps) {
  return (
    <GlassCard>
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-base font-semibold tracking-tight text-ink">Recent activity</h2>
        <span className="text-sm text-muted">latest events</span>
      </div>
      {loading ? (
        <div className="grid place-items-center py-10">
          <Spinner label="Loading activity" />
        </div>
      ) : error ? (
        <EmptyState icon="alert" title="Couldn’t load activity" description={error} />
      ) : items.length === 0 ? (
        <EmptyState icon="sparkles" title="No activity yet" description="Workspace events will appear here as they happen." />
      ) : (
        <ul className="space-y-4">
          {items.map((item) => (
            <ActivityRow key={item.id} item={item} />
          ))}
        </ul>
      )}
    </GlassCard>
  );
}
