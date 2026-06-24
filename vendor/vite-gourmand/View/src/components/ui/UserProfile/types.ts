import type { SearchResult } from '../Search/types';

/**
 * UserProfile Types
 * Widget-based profile system with role-based visibility
 * Inspired by 42's profile architecture
 */

export type UserRole = 'superadmin' | 'admin' | 'employee' | 'customer';

/* ───────────────── Full User Profile ───────────────── */

/** Complete profile data from API + computed fields */
export interface FullUserProfile {
  id: string;
  name: string;
  username: string;
  email: string;
  role: UserRole;
  avatar?: string;
  phone?: string;
  city?: string;
  country?: string;
  postalAddress?: string;
  position?: string;
  department?: string;
  joinedAt?: string;
  lastActive?: string;
  gdprConsent?: boolean;
  gdprConsentDate?: string;
  marketingConsent?: boolean;
  createdAt?: string;
  updatedAt?: string;
  // Computed
  level: number;
  levelProgress: number; // 0-100 (% toward next level)
  levelTitle: string;
  stats: ProfileStats;
  milestones: Milestone[];
}

export interface ProfileStats {
  ordersHandled: number;
  ordersCompleted: number;
  hoursWorked: number;
  averageRating: number;
  tasksCompleted: number;
  completionRate: number; // 0-100
}

export interface Milestone {
  id: string;
  icon: string;
  label: string;
  description: string;
  date?: string;
  achieved: boolean;
}

/* ───────────────── Widget System ───────────────── */

/** Props passed to every widget component */
export interface ProfileWidgetProps {
  profile: FullUserProfile;
  isSelf: boolean;
  viewerRole: UserRole;
}

/** Widget configuration — common interface all widgets share */
export interface ProfileWidgetConfig {
  id: string;
  title: string;
  icon: string;
  order: number;
  /** Which viewer roles can see this widget */
  viewerRoles: UserRole[];
  /** Which target profile roles display this widget */
  targetRoles: UserRole[];
  /** Only visible when viewing own profile */
  selfOnly?: boolean;
  /** The widget component to render */
  component: React.ComponentType<ProfileWidgetProps>;
}

/* ───────────────── Component Props ───────────────── */

export interface UserProfileProps {
  userId: string;
  onClose?: () => void;
  isModal?: boolean;
}

/* ───────────────── Legacy compat ───────────────── */

export type UserProfileData = SearchResult & Partial<Omit<FullUserProfile, keyof SearchResult>>;

export interface UserStats {
  ordersHandled?: number;
  ordersCompleted?: number;
  averageRating?: number;
  totalRevenue?: number;
  shiftsWorked?: number;
  hoursWorked?: number;
}
