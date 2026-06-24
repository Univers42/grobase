import { useEffect } from 'react';
import { useAuthStore } from '@/stores/authStore';

/**
 * Hook that exposes auth state and actions from the Zustand store.
 * Automatically triggers a session restore on first mount.
 */
export default function useBaasAuth() {
  const user       = useAuthStore((s) => s.user);
  const loading    = useAuthStore((s) => s.loading);
  const error      = useAuthStore((s) => s.error);
  const signIn     = useAuthStore((s) => s.signIn);
  const signUp     = useAuthStore((s) => s.signUp);
  const signOut    = useAuthStore((s) => s.signOut);
  const restore    = useAuthStore((s) => s.restore);

  useEffect(() => {
    restore();
  }, [restore]);

  const role = user?.user_metadata?.role || user?.app_metadata?.role || null;
  return { user, loading, error, role, signIn, signUp, signOut };
}
