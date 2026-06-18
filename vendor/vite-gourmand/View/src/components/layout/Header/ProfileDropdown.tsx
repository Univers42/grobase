/**
 * ProfileDropdown Component
 * User profile menu with login/logout functionality
 */

import { useState, useRef, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { usePortalAuth } from '../../../portal_dashboard';
import { AccountIcon } from './HeaderIcons';
import './ProfileDropdown.css';

export function ProfileDropdown() {
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const { user, isAuthenticated, logout } = usePortalAuth();
  const navigate = useNavigate();

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target;
      if (target instanceof Node && dropdownRef.current && !dropdownRef.current.contains(target)) {
        setIsOpen(false);
      }
    };
    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isOpen]);

  const handleLogout = () => {
    logout();
    setIsOpen(false);
    navigate('/portal');
  };

  const handleLogin = () => {
    setIsOpen(false);
    navigate('/portal');
  };

  return (
    <div className="profile-dropdown" ref={dropdownRef}>
      <button
        className={`header-nav-item ${isOpen ? 'header-nav-item--active' : ''}`}
        onClick={() => setIsOpen(!isOpen)}
        aria-label="Account menu"
      >
        <span className="header-nav-icon">
          <AccountIcon />
        </span>
        <span className="header-nav-label">Account</span>
      </button>

      {isOpen && (
        <div className="profile-dropdown-menu">
          {isAuthenticated && user ? (
            <>
              <div className="profile-dropdown-header">
                <div className="profile-avatar">{user.name.charAt(0).toUpperCase()}</div>
                <div className="profile-info">
                  <span className="profile-name">{user.name}</span>
                  <span className="profile-email">{user.email}</span>
                  <span className="profile-role">{user.role}</span>
                </div>
              </div>
              <div className="profile-dropdown-divider" />
              <button className="profile-dropdown-item" onClick={handleLogout}>
                <span>🚪</span>
                <span>Logout</span>
              </button>
            </>
          ) : (
            <>
              <div className="profile-dropdown-header">
                <p className="profile-guest">Not logged in</p>
              </div>
              <div className="profile-dropdown-divider" />
              <button className="profile-dropdown-item" onClick={handleLogin}>
                <span>🔑</span>
                <span>Login</span>
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}
