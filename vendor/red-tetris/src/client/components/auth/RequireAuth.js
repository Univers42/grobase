import { Navigate } from 'react-router-dom';
import { loadSession } from '../../baas/session';

/**
 * RequireAuth gates a route on a persisted Grobase session, redirecting to
 * /login when signed out. Pure functional component.
 */
const RequireAuth = ({ children }) => {
  if (!loadSession()) return <Navigate to="/login" replace />;
  return children;
};

export default RequireAuth;
