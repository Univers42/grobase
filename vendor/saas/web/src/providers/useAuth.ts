// useAuth.ts — auth state + actions over the injected client's auth surface. Keeps
// a reactive snapshot of the current user so components re-render on sign-in/out.

import { useCallback, useState } from 'react';
import type { SessionUser } from '../lib/session';
import { useBaas } from './useBaas';

/** AuthState is the reactive auth snapshot + actions returned by useAuth. */
export type AuthState = {
  user: SessionUser | null;
  isAuthed: boolean;
  signIn: (email: string, password: string) => Promise<void>;
  signUp: (email: string, password: string, username?: string) => Promise<void>;
  recover: (email: string) => Promise<void>;
  signOut: () => Promise<void>;
};

/** useAuth wires the client's auth surface to local reactive state. */
export function useAuth(): AuthState {
  const { auth } = useBaas();
  const [user, setUser] = useState<SessionUser | null>(() => auth.currentUser());

  const signIn = useCallback(
    async (email: string, password: string) => {
      const r = await auth.signInWithPassword({ email, password });
      setUser(r.user);
    },
    [auth],
  );

  const signUp = useCallback(
    async (email: string, password: string, username?: string) => {
      const r = await auth.signUp({ email, password, username });
      setUser(r.user);
    },
    [auth],
  );

  const recover = useCallback((email: string) => auth.recover({ email }), [auth]);

  const signOut = useCallback(async () => {
    await auth.signOut();
    setUser(null);
  }, [auth]);

  return { user, isAuthed: Boolean(user) || auth.isAuthed(), signIn, signUp, recover, signOut };
}
