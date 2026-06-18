import { create } from 'zustand';
import baas from '@/baas/client';

export const useAuthStore = create((set) => ({
  user: null,
  loading: true,
  error: null,

  /** Restore session from existing token */
  restore: async () => {
    set({ loading: true, error: null });
    try {
      const user = await baas.auth.getUser();
      set({ user, loading: false });
    } catch {
      set({ user: null, loading: false });
    }
  },

  /** Email + password sign-in */
  signIn: async (email, password) => {
    set({ loading: true, error: null });
    try {
      const data = await baas.auth.signIn({ email, password });
      const user = await baas.auth.getUser();
      set({ user, loading: false });
      return data;
    } catch (err) {
      set({ error: err.message, loading: false });
      throw err;
    }
  },

  /** Sign out and clear state */
  signOut: async () => {
    await baas.auth.signOut();
    set({ user: null, error: null });
  },
}));
