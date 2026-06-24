// RequireRole.tsx — route guard that admits a subtree only when the caller's
// SERVER-TRUSTED JWT role (auth.isAdmin, the top-level `role` claim the data
// plane enforces) matches. Defense-in-depth over the data plane's owner-scope:
// a customer redirected here cannot even reach the Users page UI, but the real
// enforcement is server-side (a customer's JWT sees 0 rows regardless).

import { Navigate } from 'react-router-dom';
import type { ReactNode } from 'react';
import { useAuth } from '../providers/useAuth';

/** RequireRoleProps wraps the role-gated subtree (admin-only today). */
export type RequireRoleProps = { children: ReactNode };

/** RequireRole gates a subtree behind the admin JWT role, redirecting others. */
export function RequireRole({ children }: RequireRoleProps) {
  const { isAuthed, isAdmin } = useAuth();
  if (!isAuthed) return <Navigate to="/login" replace />;
  if (!isAdmin) return <Navigate to="/app" replace />;
  return <>{children}</>;
}
