// RequireAuth.tsx — route guard: renders children only when authed, otherwise
// redirects to /login, preserving the attempted location for post-login return.

import { Navigate, useLocation } from 'react-router-dom';
import type { ReactNode } from 'react';
import { useAuth } from '../providers/useAuth';

/** RequireAuthProps wraps the protected subtree. */
export type RequireAuthProps = { children: ReactNode };

/** RequireAuth gates a subtree behind authentication. */
export function RequireAuth({ children }: RequireAuthProps) {
  const { isAuthed } = useAuth();
  const location = useLocation();
  if (!isAuthed) return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  return <>{children}</>;
}
