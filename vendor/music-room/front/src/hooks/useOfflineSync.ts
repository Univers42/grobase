import { useEffect, useRef, useState, useCallback } from 'react';
import NetInfo, { NetInfoState } from '@react-native-community/netinfo';
import { OfflineQueue } from '../services/offline';
import { api } from '../services/api';
import { useAuthStore } from '../stores/authStore';
import { useNotificationStore } from '../stores/notificationStore';

const MAX_RETRIES = 3;
const SYNC_INTERVAL_MS = 30_000; // 30 seconds

/**
 * Hook that monitors network connectivity and syncs queued offline actions
 */
export function useOfflineSync() {
  const [isOnline, setIsOnline] = useState(true);
  const [isSyncing, setIsSyncing] = useState(false);
  const [pendingCount, setPendingCount] = useState(0);
  const token = useAuthStore((s) => s.token);
  const show = useNotificationStore((s) => s.show);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const queue = OfflineQueue.getInstance();

  const updatePendingCount = useCallback(async () => {
    const count = await queue.size();
    setPendingCount(count);
  }, []);

  const syncQueue = useCallback(async () => {
    if (!token || isSyncing) return;

    const actions = await queue.getQueue();
    if (actions.length === 0) return;

    setIsSyncing(true);
    let synced = 0;

    for (const action of actions) {
      if (action.retryCount >= MAX_RETRIES) {
        // Drop actions that have exceeded max retries
        await queue.dequeue(action.id);
        continue;
      }

      try {
        switch (action.method) {
          case 'POST':
            await api.post(action.url, action.body, token);
            break;
          case 'PATCH':
            await api.patch(action.url, action.body, token);
            break;
          case 'DELETE':
            await api.delete(action.url, token);
            break;
        }
        await queue.dequeue(action.id);
        synced++;
      } catch {
        await queue.markRetry(action.id);
      }
    }

    if (synced > 0) {
      show(`Synced ${synced} offline action${synced > 1 ? 's' : ''}`, 'success');
    }

    await updatePendingCount();
    setIsSyncing(false);
  }, [token, isSyncing]);

  // Monitor network state
  useEffect(() => {
    const unsubscribe = NetInfo.addEventListener((state: NetInfoState) => {
      const wasOffline = !isOnline;
      const nowOnline = !!state.isConnected;
      setIsOnline(nowOnline);

      if (wasOffline && nowOnline) {
        show('Back online — syncing pending changes...', 'info');
        syncQueue();
      }

      if (!nowOnline) {
        show('You are offline — changes will be queued', 'warning');
      }
    });

    return () => unsubscribe();
  }, [isOnline]);

  // Periodic sync when online
  useEffect(() => {
    if (isOnline) {
      intervalRef.current = setInterval(() => {
        syncQueue();
      }, SYNC_INTERVAL_MS);
    }

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };
  }, [isOnline, syncQueue]);

  // Initial count
  useEffect(() => {
    updatePendingCount();
  }, []);

  return {
    isOnline,
    isSyncing,
    pendingCount,
    syncNow: syncQueue,
  };
}
