/**
 * Portal Auth Context
 * Provides authentication state across the dashboard
 */

import { createContext, useContext, useState, useCallback, useEffect, useMemo, type ReactNode } from 'react';
import * as authService from '../services/auth';
import type { RegisterData } from '../services/auth';
import { getRememberMe, saveRememberMe, clearRememberMe } from './rememberMe';
import type { PortalAuthState, UserRole } from './types';

interface PortalAuthContextValue extends PortalAuthState {
  login: (email: string, password: string, remember?: boolean) => Promise<void>;
  register: (data: RegisterData) => Promise<void>;
  forgotPassword: (email: string) => Promise<string>;
  loginWithGoogle: (credential: string) => Promise<void>;
  logout: () => void;
  rememberMeData: { email: string; name: string } | null;
}

const PortalAuthContext = createContext<PortalAuthContextValue | null>(null);

export function PortalAuthProvider({ children }: Readonly<{ children: ReactNode }>) {
  const [state, setState] = useState<PortalAuthState>({
    user: null,
    isAuthenticated: false,
    isLoading: true,
    error: null,
  });

  const [rememberMeData, setRememberMeData] = useState<{ email: string; name: string } | null>(
    null,
  );

  // Load remember me data and check existing session
  useEffect(() => {
    const init = async () => {
      const remembered = getRememberMe();
      if (remembered) setRememberMeData({ email: remembered.email, name: remembered.name });

      try {
        const profile = await authService.getProfile();
        const role = mapRole(profile.role);
        setState({
          user: { ...profile, role },
          isAuthenticated: true,
          isLoading: false,
          error: null,
        });
      } catch {
        setState((s) => ({ ...s, isLoading: false }));
      }
    };
    init();
  }, []);

  const login = useCallback(async (email: string, password: string, remember = false) => {
    setState((s) => ({ ...s, isLoading: true, error: null }));
    try {
      const { user } = await authService.login({ email, password });
      const role = mapRole(user.role);

      if (remember) saveRememberMe({ email: user.email, name: user.name });
      setState({ user: { ...user, role }, isAuthenticated: true, isLoading: false, error: null });
    } catch (e) {
      setState((s) => ({
        ...s,
        isLoading: false,
        error: e instanceof Error ? e.message : 'Login failed',
      }));
      throw e;
    }
  }, []);

  const loginWithGoogle = useCallback(async (credential: string) => {
    setState((s) => ({ ...s, isLoading: true, error: null }));
    try {
      const { user } = await authService.googleLogin(credential);
      const role = mapRole(user.role);
      setState({ user: { ...user, role }, isAuthenticated: true, isLoading: false, error: null });
    } catch (e) {
      setState((s) => ({
        ...s,
        isLoading: false,
        error: e instanceof Error ? e.message : 'Google login failed',
      }));
      throw e;
    }
  }, []);

  const registerUser = useCallback(async (data: RegisterData) => {
    setState((s) => ({ ...s, isLoading: true, error: null }));
    try {
      const { user } = await authService.register(data);
      const role = mapRole(user.role);
      setState({ user: { ...user, role }, isAuthenticated: true, isLoading: false, error: null });
    } catch (e) {
      setState((s) => ({
        ...s,
        isLoading: false,
        error: e instanceof Error ? e.message : "Échec de l'inscription",
      }));
      throw e;
    }
  }, []);

  const forgotPassword = useCallback(async (email: string): Promise<string> => {
    setState((s) => ({ ...s, isLoading: true, error: null }));
    try {
      const result = await authService.forgotPassword(email);
      setState((s) => ({ ...s, isLoading: false }));
      return result.message;
    } catch (e) {
      setState((s) => ({
        ...s,
        isLoading: false,
        error: e instanceof Error ? e.message : "Échec de l'envoi",
      }));
      throw e;
    }
  }, []);

  const logout = useCallback(() => {
    authService.logout();
    clearRememberMe();
    setState({ user: null, isAuthenticated: false, isLoading: false, error: null });
  }, []);

  const value = useMemo(
    () => ({
      ...state,
      login,
      register: registerUser,
      forgotPassword,
      loginWithGoogle,
      logout,
      rememberMeData,
    }),
    [state, login, registerUser, forgotPassword, loginWithGoogle, logout, rememberMeData],
  );

  return (
    <PortalAuthContext.Provider value={value}>
      {children}
    </PortalAuthContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function usePortalAuth() {
  const ctx = useContext(PortalAuthContext);
  if (!ctx) throw new Error('usePortalAuth must be used within PortalAuthProvider');
  return ctx;
}

/** Map API role to dashboard role */
function mapRole(apiRole: string): UserRole {
  const normalizedRole = apiRole?.toLowerCase() || '';
  if (normalizedRole === 'superadmin') return 'superadmin';
  if (normalizedRole === 'admin') return 'admin';
  if (normalizedRole === 'employee') return 'employee';
  return 'customer'; // Default for client/customer roles
}
