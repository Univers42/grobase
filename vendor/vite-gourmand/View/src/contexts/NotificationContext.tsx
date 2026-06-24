/**
 * NotificationContext — Global notification state for authenticated users.
 *
 * • Polls `/api/notifications` every 30 s while the user is logged-in.
 * • Exposes unread count, notification list, and actions (dismiss, mark read).
 * • Only activates when a valid auth token exists — no wasted calls for guests.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import {
  getNotifications,
  getUnreadCount,
  markAsRead,
  markAllAsRead,
  deleteNotification,
  type Notification,
} from '../services/notifications';
import { isAuthenticated } from '../services/api';

/* ------------------------------------------------------------------ */
/*  Types                                                              */
/* ------------------------------------------------------------------ */

export interface NotificationState {
  /** All recent notifications */
  notifications: Notification[];
  /** Number of unread notifications */
  unreadCount: number;
  /** Whether the notification panel is open */
  isOpen: boolean;
  /** IDs that the user dismissed locally (hidden from toast) */
  dismissedIds: Set<number>;
  /** Toggle the panel open/closed */
  toggle: () => void;
  /** Close the panel */
  close: () => void;
  /** Dismiss a single notification locally (hides it) */
  dismiss: (id: number) => void;
  /** Mark a single notification as read on the server */
  read: (id: number) => Promise<void>;
  /** Mark all as read */
  readAll: () => Promise<void>;
  /** Remove a notification permanently */
  remove: (id: number) => Promise<void>;
  /** Force-refresh from server */
  refresh: () => Promise<void>;
}

const defaultState: NotificationState = {
  notifications: [],
  unreadCount: 0,
  isOpen: false,
  dismissedIds: new Set(),
  toggle: () => {},
  close: () => {},
  dismiss: () => {},
  read: async () => {},
  readAll: async () => {},
  remove: async () => {},
  refresh: async () => {},
};

/* ------------------------------------------------------------------ */
/*  Context & hook                                                     */
/* ------------------------------------------------------------------ */

const NotificationCtx = createContext<NotificationState>(defaultState);

// eslint-disable-next-line react-refresh/only-export-components
export function useNotifications(): NotificationState {
  return useContext(NotificationCtx);
}

/* ------------------------------------------------------------------ */
/*  Provider                                                           */
/* ------------------------------------------------------------------ */

const POLL_INTERVAL = 30_000; // 30 seconds

export function NotificationProvider({
  children,
  enabled = true,
}: Readonly<{
  children: ReactNode;
  enabled?: boolean;
}>) {
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const [unreadCount, setUnreadCount] = useState(0);
  const [isOpen, setIsOpen] = useState(false);
  const [dismissedIds, setDismissedIds] = useState<Set<number>>(new Set());
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  /** Set to true after a 401 — prevents any further network calls */
  const stoppedRef = useRef(false);

  /** Kill the polling interval immediately */
  const stopPolling = useCallback(() => {
    stoppedRef.current = true;
    if (intervalRef.current) {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
  }, []);

  // ── Fetch from backend ──
  const refresh = useCallback(async () => {
    if (!enabled || stoppedRef.current || !isAuthenticated()) return;
    try {
      const [notifs, count] = await Promise.all([getNotifications(30), getUnreadCount()]);
      setNotifications(notifs);
      setUnreadCount(count);
    } catch (err: unknown) {
      // On 401 → token is invalid, stop polling permanently
      if (
        err &&
        typeof err === 'object' &&
        'status' in err &&
        (err as { status: number }).status === 401
      ) {
        stopPolling();
      }
      // Other errors: silently ignore (network blip, server down, etc.)
    }
  }, [enabled, stopPolling]);

  // ── Polling ──
  useEffect(() => {
    if (!enabled || !isAuthenticated()) {
      stopPolling();
      setNotifications([]);
      setUnreadCount(0);
      setIsOpen(false);
      return;
    }

    stoppedRef.current = false;

    // Initial fetch
    refresh();

    intervalRef.current = setInterval(refresh, POLL_INTERVAL);
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [enabled, refresh, stopPolling]);

  // ── Actions ──
  const toggle = useCallback(() => {
    if (!enabled || !isAuthenticated()) return;
    setIsOpen((prev) => !prev);
  }, [enabled]);
  const close = useCallback(() => setIsOpen(false), []);

  const dismiss = useCallback((id: number) => {
    setDismissedIds((prev) => new Set(prev).add(id));
  }, []);

  const read = useCallback(async (id: number) => {
    if (!enabled || !isAuthenticated()) return;
    try {
      await markAsRead(id);
      setNotifications((prev) =>
        prev.map((n) =>
          n.id === id ? { ...n, is_read: true, read_at: new Date().toISOString() } : n,
        ),
      );
      setUnreadCount((prev) => Math.max(0, prev - 1));
    } catch {
      // ignore
    }
  }, [enabled]);

  const readAll = useCallback(async () => {
    if (!enabled || !isAuthenticated()) return;
    try {
      await markAllAsRead();
      setNotifications((prev) =>
        prev.map((n) => ({ ...n, is_read: true, read_at: new Date().toISOString() })),
      );
      setUnreadCount(0);
    } catch {
      // ignore
    }
  }, [enabled]);

  const remove = useCallback(
    async (id: number) => {
      if (!enabled || !isAuthenticated()) return;
      try {
        await deleteNotification(id);
        setNotifications((prev) => prev.filter((n) => n.id !== id));
        setUnreadCount((prev) => Math.max(0, prev - 1));
        dismiss(id);
      } catch {
        // ignore
      }
    },
    [dismiss, enabled],
  );

  const value = useMemo<NotificationState>(
    () => ({
      notifications,
      unreadCount,
      isOpen,
      dismissedIds,
      toggle,
      close,
      dismiss,
      read,
      readAll,
      remove,
      refresh,
    }),
    [
      notifications,
      unreadCount,
      isOpen,
      dismissedIds,
      toggle,
      close,
      dismiss,
      read,
      readAll,
      remove,
      refresh,
    ],
  );

  return (
    <NotificationCtx.Provider value={value}>
      {children}
    </NotificationCtx.Provider>
  );
}
