// PagesList.tsx — a read-only list of the tenant's `type='page'` content docs,
// loaded from the Mongo mount. Surfaces each page's logical key as a glass row.

import { useEffect, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import { asString } from '../../lib/guards';
import { GlassCard } from '../../ds/GlassCard';
import { EmptyState } from '../../ds/EmptyState';
import { Badge } from '../../ds/Badge';
import { Icon } from '../../ds/Icon';

/** PageRow is the minimal projection of a content page rendered in the list. */
type PageRow = { key: string; updatedAt: string };

/** PagesList renders the read-only catalog of content pages. */
export function PagesList() {
  const { db } = useBaas();
  const [pages, setPages] = useState<PageRow[]>([]);

  useEffect(() => {
    let cancelled = false;
    db.mongo
      .list('content', { filter: { type: { $eq: 'page' } }, sort: { updated_at: 'desc' } })
      .then((r) => {
        if (cancelled) return;
        setPages(r.rows.map((row) => ({ key: asString(row.key), updatedAt: asString(row.updated_at) })));
      })
      .catch(() => !cancelled && setPages([]));
    return () => {
      cancelled = true;
    };
  }, [db]);

  return (
    <GlassCard className="space-y-3">
      <h2 className="text-sm font-semibold text-ink">Content pages</h2>
      {pages.length === 0 ? (
        <EmptyState icon="content" title="No pages yet" description="Pages authored in your content store appear here." />
      ) : (
        <ul className="space-y-2">
          {pages.map((page) => (
            <li key={page.key} className="glass flex items-center justify-between rounded-2xl px-4 py-3">
              <span className="flex items-center gap-2.5 text-sm text-ink">
                <Icon name="content" size={16} className="text-accent" />
                {page.key}
              </span>
              <Badge tone="neutral">read-only</Badge>
            </li>
          ))}
        </ul>
      )}
    </GlassCard>
  );
}
