import { create } from 'zustand';

export type SnackbarType = 'info' | 'success' | 'error' | 'warning';

interface SnackbarMessage {
  id: string;
  text: string;
  type: SnackbarType;
  duration?: number;
}

interface NotificationStore {
  messages: SnackbarMessage[];
  show: (text: string, type?: SnackbarType, duration?: number) => void;
  dismiss: (id: string) => void;
  clear: () => void;
}

let counter = 0;

export const useNotificationStore = create<NotificationStore>((set) => ({
  messages: [],

  show: (text, type = 'info', duration = 3000) => {
    const id = `snack_${++counter}`;
    set((state) => ({
      messages: [...state.messages, { id, text, type, duration }],
    }));

    // Auto-dismiss
    if (duration > 0) {
      setTimeout(() => {
        set((state) => ({
          messages: state.messages.filter((m) => m.id !== id),
        }));
      }, duration);
    }
  },

  dismiss: (id) =>
    set((state) => ({
      messages: state.messages.filter((m) => m.id !== id),
    })),

  clear: () => set({ messages: [] }),
}));
