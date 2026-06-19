import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';
import { readConfig, type BaasConfig } from '../baas/config.ts';
import { signOut as baasSignOut } from '../baas/auth.ts';
import { loadSession, saveSession, type Session } from '../baas/session.ts';

type AuthValue = {
  cfg: BaasConfig;
  session: Session | null;
  setSession: (s: Session | null) => void;
  logout: () => Promise<void>;
};

const AuthContext = createContext<AuthValue | null>(null);

/** AuthProvider holds the Grobase config and the current GoTrue session. */
export function AuthProvider({ children }: { children: ReactNode }) {
  const cfg = useMemo(readConfig, []);
  const [session, setSessionState] = useState<Session | null>(loadSession);
  const setSession = useCallback((s: Session | null) => {
    saveSession(s);
    setSessionState(s);
  }, []);
  const logout = useCallback(async () => {
    await baasSignOut(cfg);
    setSessionState(null);
  }, [cfg]);
  const value = useMemo(() => ({ cfg, session, setSession, logout }), [cfg, session, setSession, logout]);
  return <AuthContext value={value}>{children}</AuthContext>;
}

/** useAuth returns the auth context, throwing outside the provider. */
export function useAuth(): AuthValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
