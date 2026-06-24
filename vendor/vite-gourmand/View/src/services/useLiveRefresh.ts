/**
 * useLiveRefresh — drop-in Grobase realtime for any data view.
 *
 * Subscribes to the agnostic-realtime change stream of every table in `tables`
 * and invokes `reload` (debounced) whenever any of them changes — so a write
 * anywhere (DevBoard edit, another client, a DB trigger) refreshes this view
 * with no manual refresh. Pass a SILENT reload (one that does not toggle a
 * loading spinner) so updates apply in place without a "stale then fresh" flash.
 */

import { useEffect, useRef } from 'react';
import { subscribeTable } from './baas';
import { dbIdForTable } from './baas-crud';

export function useLiveRefresh(tables: string[], reload: () => void, debounceMs = 250): void {
  const reloadRef = useRef(reload);
  reloadRef.current = reload;
  const key = tables.join(',');
  useEffect(() => {
    if (!key) return;
    const names = key.split(',');
    let timer: ReturnType<typeof setTimeout> | null = null;
    const fire = () => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => reloadRef.current(), debounceMs);
    };
    const unsubs = names.map((t) => subscribeTable(dbIdForTable(t), t, fire));
    return () => {
      if (timer) clearTimeout(timer);
      unsubs.forEach((u) => u());
    };
  }, [key, debounceMs]);
}
