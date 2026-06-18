/**
 * Portal Dashboard Types
 * Role-based access definitions
 */

export type UserRole = 'superadmin' | 'admin' | 'employee' | 'customer';

/** Bot identifiers for debugging */
export type BotId = 'bot_admin' | 'bot_employee' | 'bot_user';

export interface DashboardUser {
  id: number;
  email: string;
  name: string;
  role: UserRole;
  avatar?: string;
  isBot?: boolean;
}

export interface RememberMeData {
  email: string;
  name: string;
  avatar?: string;
  timestamp: number;
}

export interface PortalAuthState {
  user: DashboardUser | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  error: string | null;
}

/** Bot users for debugging (superadmin only) */
export const DEBUG_BOTS: Record<BotId, DashboardUser> = {
  bot_admin: { id: -1, email: 'bot_admin@debug', name: 'Bot Admin', role: 'admin', isBot: true },
  bot_employee: {
    id: -2,
    email: 'bot_employee@debug',
    name: 'Bot Employee',
    role: 'employee',
    isBot: true,
  },
  bot_user: {
    id: -3,
    email: 'bot_user@debug',
    name: 'Bot Customer',
    role: 'customer',
    isBot: true,
  },
};

/** Role-based permissions */
export const ROLE_PERMISSIONS: Record<UserRole, string[]> = {
  superadmin: ['*'], // All access + debug tools
  admin: ['metrics', 'activity', 'database', 'logs', 'settings', 'orders', 'users'],
  employee: ['tasks', 'orders', 'activity', 'database'],
  customer: ['orders', 'loyalty', 'support', 'reviews', 'profile'], // Client dashboard
};

/** Check if role has permission */
export function hasPermission(role: UserRole, permission: string): boolean {
  const perms = ROLE_PERMISSIONS[role];
  return perms.includes('*') || perms.includes(permission);
}

/** Check if role can access dashboard */
export function canAccessDashboard(_role: UserRole): boolean {
  return true; // All authenticated roles can access their dashboard
}
