import { useEffect, useRef, useState } from 'react';
import { subscribe } from '@/baas/client';

/**
 * Hook for real-time BaaS subscriptions.
 *
 * @param {string}   collection — collection to watch
 * @param {string}   event      — 'insert' | 'update' | 'delete' | '*'
 * @param {function} callback   — called with the changed document
 * @param {object}   [options]
 * @param {boolean}  [options.enabled=true]
 */
export default function useBaasRealtime(collection, event, callback, options = {}) {
  const { enabled = true } = options;
  const cbRef = useRef(callback);
  const [connected, setConnected] = useState(false);

  // Keep ref fresh without re-subscribing
  useEffect(() => {
    cbRef.current = callback;
  }, [callback]);

  useEffect(() => {
    if (!enabled) return;

    const unsub = subscribe(collection, event, (doc) => {
      setConnected(true);
      cbRef.current(doc);
    });

    setConnected(true);
    return () => {
      unsub();
      setConnected(false);
    };
  }, [collection, event, enabled]);

  return { connected };
}
