import { useEffect } from 'react';
import { useAuthStore } from '@/stores/authStore';

/** Exposes auth state + actions; restores the session on first mount. */
export default function useBaasAuth() {
  const user = useAuthStore((s) => s.user);
  const loading = useAuthStore((s) => s.loading);
  const error = useAuthStore((s) => s.error);
  const signIn = useAuthStore((s) => s.signIn);
  const signUp = useAuthStore((s) => s.signUp);
  const signOut = useAuthStore((s) => s.signOut);
  const restore = useAuthStore((s) => s.restore);

  useEffect(() => { restore(); }, [restore]);

  const role = user?.app_metadata?.role || null;
  const name = user?.user_metadata?.full_name || user?.email?.split('@')[0] || null;
  return { user, loading, error, role, name, signIn, signUp, signOut };
}
