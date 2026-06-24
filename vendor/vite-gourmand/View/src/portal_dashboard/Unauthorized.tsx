/**
 * Unauthorized Page
 * Shown when user lacks permissions for a route
 */

import { useNavigate } from 'react-router-dom';
import { usePortalAuth } from './PortalAuthContext';
import { GradientBackground } from '../components/DevBoard/GradientBackground';
import './Unauthorized.css';

export function Unauthorized() {
  const navigate = useNavigate();
  const { user, logout } = usePortalAuth();

  const handleGoBack = () => {
    navigate(-1);
  };

  const handleLogout = () => {
    logout();
    navigate('/portal');
  };

  return (
    <div className="unauthorized-page">
      <GradientBackground />
      <div className="unauthorized-card">
        <span className="unauthorized-icon">🚫</span>
        <h1>Access Denied</h1>
        <p>You don't have permission to access this page.</p>

        {user && (
          <p className="unauthorized-role">
            Your role: <strong>{user.role}</strong>
          </p>
        )}

        <div className="unauthorized-actions">
          <button onClick={handleGoBack} className="btn-secondary">
            Go Back
          </button>
          <button onClick={handleLogout} className="btn-primary">
            Switch Account
          </button>
        </div>
      </div>
    </div>
  );
}
