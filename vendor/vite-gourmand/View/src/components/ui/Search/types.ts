/**
 * Search Types - User search and visibility
 */

export interface SearchResult {
  id: string;
  name: string;
  username: string;
  email: string;
  role: UserVisibility;
  avatar?: string;
  createdAt?: string;
}

export type UserVisibility = 'superadmin' | 'admin' | 'employee' | 'customer';

/**
 * Visibility Rules:
 * - superadmin: can see everyone
 * - admin: can see other admins + all employees
 * - employee: can see only other employees (transparency)
 * - customer: can only see their own profile
 */
export interface VisibilityRules {
  [key: string]: UserVisibility[];
}

export interface UserProfile extends SearchResult {
  phone?: string;
  address?: string;
  position?: string;
  department?: string;
  startDate?: string;
  stats?: UserStats;
}

export interface UserStats {
  ordersHandled?: number;
  hoursWorked?: number;
  averageRating?: number;
  tasksCompleted?: number;
}
