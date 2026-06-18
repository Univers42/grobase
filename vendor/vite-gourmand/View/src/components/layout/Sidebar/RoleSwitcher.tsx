/**
 * RoleSwitcher - Sidebar dropdown for switching between role views
 * Role-based visibility:
 * - superadmin: can see dev, admin, employee
 * - admin: can see admin, employee
 * - employee: can see only employee (no switcher shown)
 */

import { useState, useMemo } from 'react';
import { usePortalAuth } from '../../../portal_dashboard';
import { useRoleView } from '../../DevBoard/RoleViewContext';
import type { RoleView } from '../../DevBoard/constants';
import './RoleSwitcher.css';

interface RoleOption {
  id: RoleView;
  label: string;
  icon: string;
  description: string;
  allowedRoles: string[]; // Which user roles can access this view
}

const ROLE_OPTIONS: RoleOption[] = [
  {
    id: 'dev',
    label: 'DevBoard',
    icon: '🛠️',
    description: 'QA & Development',
    allowedRoles: ['superadmin'],
  },
  {
    id: 'admin',
    label: 'Admin',
    icon: '👔',
    description: 'Administration',
    allowedRoles: ['superadmin', 'admin'],
  },
  {
    id: 'employee',
    label: 'Employé',
    icon: '👷',
    description: 'Espace Employé',
    allowedRoles: ['superadmin', 'admin', 'employee'],
  },
  {
    id: 'client',
    label: 'Client',
    icon: '👤',
    description: 'Mon Espace',
    allowedRoles: ['superadmin', 'admin', 'customer'],
  },
];

/** Get available views for a user role */
// eslint-disable-next-line react-refresh/only-export-components
export function getAvailableViews(userRole: string): RoleOption[] {
  return ROLE_OPTIONS.filter((opt) => opt.allowedRoles.includes(userRole));
}

/** Get default view for a user role */
// eslint-disable-next-line react-refresh/only-export-components
export function getDefaultViewForRole(userRole: string): RoleView {
  switch (userRole) {
    case 'superadmin':
      return 'dev';
    case 'admin':
      return 'admin';
    case 'employee':
      return 'employee';
    case 'customer':
      return 'client';
    default:
      return 'employee';
  }
}

interface RoleSwitcherProps {
  collapsed?: boolean;
}

export function RoleSwitcher({ collapsed }: Readonly<RoleSwitcherProps>) {
  const { user } = usePortalAuth();
  const { currentView, setView } = useRoleView();
  const [isOpen, setIsOpen] = useState(false);

  // Get available views for current user
  const availableViews = useMemo(() => {
    if (!user?.role) return [];
    return getAvailableViews(user.role);
  }, [user?.role]);

  // Don't show switcher if user has only one view available
  if (availableViews.length <= 1) return null;

  const currentRole = availableViews.find((r) => r.id === currentView) || availableViews[0];

  const handleSelect = (role: RoleOption) => {
    setView(role.id);
    setIsOpen(false);
  };

  if (collapsed) {
    return (
      <div className="role-switcher role-switcher--collapsed">
        <button
          className="role-switcher-toggle"
          onClick={() => setIsOpen(!isOpen)}
          title="Switch View"
        >
          {currentRole.icon}
        </button>
        {isOpen && (
          <div className="role-switcher-dropdown role-switcher-dropdown--right">
            {availableViews.map((role) => (
              <button
                key={role.id}
                className={`role-option ${currentRole.id === role.id ? 'active' : ''}`}
                onClick={() => handleSelect(role)}
              >
                <span className="role-option-icon">{role.icon}</span>
                <span className="role-option-label">{role.label}</span>
              </button>
            ))}
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="role-switcher">
      <button
        className="role-switcher-toggle"
        onClick={() => setIsOpen(!isOpen)}
        aria-expanded={isOpen}
      >
        <span className="role-switcher-icon">{currentRole.icon}</span>
        <span className="role-switcher-info">
          <span className="role-switcher-label">Vue: {currentRole.label}</span>
          <span className="role-switcher-hint">{currentRole.description}</span>
        </span>
        <span className={`role-switcher-arrow ${isOpen ? 'open' : ''}`}>▼</span>
      </button>

      {isOpen && (
        <div className="role-switcher-dropdown">
          <div className="role-dropdown-header">Changer de vue</div>
          {availableViews.map((role) => (
            <button
              key={role.id}
              className={`role-option ${currentRole.id === role.id ? 'active' : ''}`}
              onClick={() => handleSelect(role)}
            >
              <span className="role-option-icon">{role.icon}</span>
              <div className="role-option-content">
                <span className="role-option-label">{role.label}</span>
                <span className="role-option-desc">{role.description}</span>
              </div>
              {currentRole.id === role.id && <span className="role-option-check">✓</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
