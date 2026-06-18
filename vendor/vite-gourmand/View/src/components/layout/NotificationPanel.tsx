/**
 * NotificationPanel — Floating notification list below the navbar.
 *
 * Slides down from the navbar and shows all recent notifications.
 * Each notification can be individually dismissed (close button).
 * Only rendered when the user is authenticated and the panel is open.
 */

import { useEffect, useRef } from 'react';
import { X, Bell, ShoppingCart, Star, Megaphone, Settings, CheckCheck } from 'lucide-react';
import { useNotifications } from '../../contexts/NotificationContext';
import './NotificationPanel.css';

/* ── Type-based styling ── */

const TYPE_CONFIG: Record<string, { icon: typeof Bell; color: string; bg: string }> = {
  order_update: { icon: ShoppingCart, color: 'text-blue-600', bg: 'bg-blue-50' },
  review: { icon: Star, color: 'text-amber-600', bg: 'bg-amber-50' },
  promo: { icon: Megaphone, color: 'text-[#722F37]', bg: 'bg-[#722F37]/5' },
  system: { icon: Settings, color: 'text-gray-600', bg: 'bg-gray-50' },
};

function getTypeConfig(type: string) {
  return TYPE_CONFIG[type] ?? TYPE_CONFIG.system;
}

/** Human-friendly relative time */
function timeAgo(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return "À l'instant";
  if (mins < 60) return `Il y a ${mins} min`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `Il y a ${hrs}h`;
  const days = Math.floor(hrs / 24);
  if (days < 7) return `Il y a ${days}j`;
  return new Date(iso).toLocaleDateString('fr-FR', { day: 'numeric', month: 'short' });
}

/* ── Panel component ── */

interface NotificationPanelProps {
  /** CSS top offset so the panel sits right below the fixed navbar */
  topOffset: number;
}

export default function NotificationPanel({ topOffset }: Readonly<NotificationPanelProps>) {
  const { notifications, unreadCount, isOpen, dismissedIds, close, dismiss, readAll } =
    useNotifications();
  const panelRef = useRef<HTMLDivElement>(null);

  // Close when clicking outside
  useEffect(() => {
    if (!isOpen) return;
    const handler = (e: MouseEvent) => {
      const target = e.target;
      if (!(target instanceof Node)) return;

      if (panelRef.current && !panelRef.current.contains(target)) {
        // Don't close if clicking the bell button (it toggles)
        const bell = target instanceof Element ? target.closest('[data-notification-bell]') : null;
        if (!bell) close();
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [isOpen, close]);

  // Close on Escape
  useEffect(() => {
    if (!isOpen) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [isOpen, close]);

  // Filter out locally dismissed
  const visible = notifications.filter((n) => !dismissedIds.has(n.id));

  if (!isOpen) return null;

  return (
    <section
      ref={panelRef}
      className="notification-panel-shell fixed right-4 sm:right-6 z-[55] w-[min(380px,calc(100vw-2rem))]"
      style={{
        top: `${topOffset + 8}px`,
      }}
      aria-label="Notifications"
    >
      <div className="bg-white rounded-xl shadow-2xl shadow-black/10 border border-[#1A1A1A]/5 overflow-hidden">
        {/* ── Header ── */}
        <div className="flex items-center justify-between px-4 py-2.5 border-b border-[#1A1A1A]/5 bg-[#FFF8F0]">
          <div className="flex items-center gap-2">
            <Bell className="w-4 h-4 text-[#722F37]" />
            <span className="font-semibold text-sm text-[#1A1A1A]">Notifications</span>
            {unreadCount > 0 && (
              <span className="bg-[#722F37] text-white text-[10px] font-bold px-1.5 py-0.5 rounded-full min-w-[18px] text-center">
                {unreadCount}
              </span>
            )}
          </div>
          <div className="flex items-center gap-1">
            {unreadCount > 0 && (
              <button
                onClick={readAll}
                className="text-[11px] text-[#722F37] hover:text-[#722F37]/80 font-medium px-2 py-1 rounded hover:bg-[#722F37]/5 transition-colors flex items-center gap-1"
                title="Tout marquer comme lu"
              >
                <CheckCheck className="w-3 h-3" />
                <span className="hidden sm:inline">Tout lu</span>
              </button>
            )}
            <button
              onClick={close}
              className="p-1 rounded hover:bg-[#1A1A1A]/5 transition-colors"
              aria-label="Fermer les notifications"
            >
              <X className="w-4 h-4 text-[#1A1A1A]/40" />
            </button>
          </div>
        </div>

        {/* ── List ── */}
        <div className="max-h-[min(400px,60vh)] overflow-y-auto">
          {visible.length === 0 ? (
            <div className="py-10 text-center">
              <Bell className="w-8 h-8 text-[#1A1A1A]/10 mx-auto mb-2" />
              <p className="text-sm text-[#1A1A1A]/40">Aucune notification</p>
            </div>
          ) : (
            visible.map((notif) => {
              const cfg = getTypeConfig(notif.type);
              const Icon = cfg.icon;
              const unreadClass = notif.is_read ? '' : 'bg-[#722F37]/[0.02]';
              const titleClass = notif.is_read
                ? 'font-medium text-[#1A1A1A]/70'
                : 'font-semibold text-[#1A1A1A]';
              return (
                <article
                  key={notif.id}
                  className={`group relative flex gap-3 px-4 py-3 border-b border-[#1A1A1A]/[0.03] transition-colors hover:bg-[#FFF8F0]/60 ${unreadClass}`}
                >
                  {/* Icon */}
                  <div
                    className={`flex-shrink-0 w-8 h-8 rounded-lg ${cfg.bg} flex items-center justify-center mt-0.5`}
                  >
                    <Icon className={`w-4 h-4 ${cfg.color}`} />
                  </div>

                  {/* Content */}
                  <div className="flex-1 min-w-0">
                    {notif.title && (
                      <p className={`text-sm leading-tight ${titleClass}`}>{notif.title}</p>
                    )}
                    {notif.body && (
                      <p className="text-xs text-[#1A1A1A]/50 leading-relaxed mt-0.5 line-clamp-2">
                        {notif.body}
                      </p>
                    )}
                    <span className="text-[10px] text-[#1A1A1A]/30 mt-1 block">
                      {timeAgo(notif.created_at)}
                    </span>
                  </div>

                  {/* Unread dot */}
                  {!notif.is_read && (
                    <div className="flex-shrink-0 w-2 h-2 rounded-full bg-[#722F37] mt-2" />
                  )}

                  {/* Dismiss button */}
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      dismiss(notif.id);
                    }}
                    className="absolute top-2 right-2 p-1.5 sm:p-0.5 rounded opacity-100 sm:opacity-0 group-hover:opacity-100 transition-opacity hover:bg-[#1A1A1A]/5"
                    aria-label="Masquer cette notification"
                  >
                    <X className="w-3.5 h-3.5 sm:w-3 sm:h-3 text-[#1A1A1A]/30" />
                  </button>
                </article>
              );
            })
          )}
        </div>
      </div>
    </section>
  );
}
