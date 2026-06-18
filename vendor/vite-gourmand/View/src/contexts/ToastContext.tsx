/**
 * ToastContext - Lightweight toast notification system
 *
 * Provides addToast() globally for ephemeral action confirmations
 * (e.g. "Email envoyé", "Inscription réussie", "Commande validée").
 */
import {
  createContext,
  useContext,
  useState,
  useCallback,
  useMemo,
  useRef,
  type ReactNode,
} from 'react';
import { X, CheckCircle2, AlertTriangle, Info, XCircle } from 'lucide-react';

/* ── Types ── */
export type ToastType = 'success' | 'error' | 'info' | 'warning';

interface Toast {
  id: string;
  message: string;
  type: ToastType;
  /** ms before auto-dismiss (0 = manual only) */
  duration: number;
}

interface ToastContextValue {
  addToast: (message: string, type?: ToastType, duration?: number) => void;
}

type ToastProviderProps = Readonly<{
  children: ReactNode;
}>;

type ToastItemProps = Readonly<{
  toast: Toast;
  onDismiss: (id: string) => void;
}>;

const ToastContext = createContext<ToastContextValue | null>(null);

/* ── Hook ── */
// eslint-disable-next-line react-refresh/only-export-components
export function useToast(): ToastContextValue {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast must be used within <ToastProvider>');
  return ctx;
}

/* ── Provider ── */
export function ToastProvider({ children }: ToastProviderProps) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const counterRef = useRef(0);

  const removeToast = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const addToast = useCallback(
    (message: string, type: ToastType = 'info', duration = 5000) => {
      const id = `toast-${++counterRef.current}`;
      setToasts((prev) => [...prev, { id, message, type, duration }]);

      if (duration > 0) {
        setTimeout(() => removeToast(id), duration);
      }
    },
    [removeToast],
  );

  const value = useMemo(() => ({ addToast }), [addToast]);

  return (
    <ToastContext.Provider value={value}>
      {children}
      {/* Toast container — bottom-right, stacked */}
      <section
        aria-live="polite"
        aria-label="Notifications"
        className="fixed bottom-4 right-4 z-[100] flex flex-col-reverse gap-2 pointer-events-none max-w-sm w-full"
      >
        {toasts.map((toast) => (
          <ToastItem key={toast.id} toast={toast} onDismiss={removeToast} />
        ))}
      </section>
    </ToastContext.Provider>
  );
}

/* ── Single toast item ── */
const STYLE: Record<ToastType, { bg: string; icon: typeof CheckCircle2; iconColor: string }> = {
  success: {
    bg: 'bg-emerald-50 border-emerald-300 text-emerald-900',
    icon: CheckCircle2,
    iconColor: 'text-emerald-600',
  },
  error: { bg: 'bg-red-50 border-red-300 text-red-900', icon: XCircle, iconColor: 'text-red-600' },
  warning: {
    bg: 'bg-amber-50 border-amber-300 text-amber-900',
    icon: AlertTriangle,
    iconColor: 'text-amber-600',
  },
  info: { bg: 'bg-blue-50 border-blue-300 text-blue-900', icon: Info, iconColor: 'text-blue-600' },
};

function ToastItem({ toast, onDismiss }: ToastItemProps) {
  const style = STYLE[toast.type];
  const Icon = style.icon;

  return (
    <div
      role="alert"
      className={`pointer-events-auto flex items-start gap-3 px-4 py-3 rounded-xl border shadow-lg backdrop-blur-sm
        ${style.bg}
        animate-[slideInRight_0.3s_ease-out]`}
    >
      <Icon className={`h-5 w-5 shrink-0 mt-0.5 ${style.iconColor}`} />
      <p className="text-sm font-medium flex-1 leading-snug">{toast.message}</p>
      <button
        onClick={() => onDismiss(toast.id)}
        className="shrink-0 p-0.5 rounded hover:bg-black/5 transition-colors"
        aria-label="Fermer la notification"
      >
        <X className="h-4 w-4 opacity-50 hover:opacity-100" />
      </button>
    </div>
  );
}
