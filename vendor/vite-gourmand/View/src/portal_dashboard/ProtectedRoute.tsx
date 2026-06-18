/**
 * Protected Route Component
 * Guards routes based on user role
 */

import { Navigate } from 'react-router-dom';
import { usePortalAuth } from './PortalAuthContext';
import type { UserRole } from './types';
import { hasPermission, canAccessDashboard } from './types';

interface ProtectedRouteProps {
  children: React.ReactNode;
  allowedRoles?: UserRole[];
  requiredPermission?: string;
}

export function ProtectedRoute({
  children,
  allowedRoles,
  requiredPermission,
}: Readonly<ProtectedRouteProps>) {
  const { isAuthenticated, isLoading, user } = usePortalAuth();

  if (isLoading) {
    return <LoadingScreen />;
  }

  if (!isAuthenticated || !user) {
    return <Navigate to="/portal" replace />;
  }

  // Customers cannot access any dashboard
  if (!canAccessDashboard(user.role)) {
    return <Navigate to="/unauthorized" replace />;
  }

  // Superadmin has access to everything
  if (user.role === 'superadmin') {
    return <>{children}</>;
  }

  // Check role-based access
  if (allowedRoles && !allowedRoles.includes(user.role)) {
    return <Navigate to="/unauthorized" replace />;
  }

  // Check permission-based access
  if (requiredPermission && !hasPermission(user.role, requiredPermission)) {
    return <Navigate to="/unauthorized" replace />;
  }

  return <>{children}</>;
}

function LoadingScreen() {
  return (
    <div className="loading-screen">
      <div className="loading-spinner" />
    </div>
  );
}
