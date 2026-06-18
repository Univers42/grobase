import { DevBoard } from '../components/DevBoard';
import { Portal } from './Portal';
import { PortalAuthProvider } from './PortalAuthContext';
import { ProtectedRoute } from './ProtectedRoute';
import { ResetPasswordPage } from './ResetPasswordPage';
import { Unauthorized } from './Unauthorized';

export function PortalRoute() {
  return (
    <PortalAuthProvider>
      <Portal />
    </PortalAuthProvider>
  );
}

export function ResetPasswordRoute() {
  return (
    <PortalAuthProvider>
      <ResetPasswordPage />
    </PortalAuthProvider>
  );
}

export function UnauthorizedRoute() {
  return (
    <PortalAuthProvider>
      <Unauthorized />
    </PortalAuthProvider>
  );
}

export function DashboardRoute() {
  return (
    <PortalAuthProvider>
      <ProtectedRoute allowedRoles={['superadmin', 'admin', 'employee', 'customer']}>
        <DevBoard />
      </ProtectedRoute>
    </PortalAuthProvider>
  );
}
