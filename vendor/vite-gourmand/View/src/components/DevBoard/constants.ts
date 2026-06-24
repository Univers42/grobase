/**
 * DevBoard constants
 * Unified category structure for all role views
 */

import type { CategoryData, TestCategory } from '../features/qa/sidebar';

/** Role view types */
export type RoleView = 'dev' | 'admin' | 'employee' | 'client';

/** DEV categories - QA & Development tools */
export const DEV_CATEGORIES: CategoryData[] = [
  {
    id: 'overview',
    label: 'Overview',
    icon: 'overview',
    count: 0,
    group: 'main',
    description: 'Dashboard overview',
  },
  {
    id: 'test-automatics',
    label: 'Tests Auto',
    icon: 'tests',
    group: 'main',
    description: 'Automated tests',
  },
  {
    id: 'scenarios',
    label: 'Scénarios',
    icon: 'scenarios',
    count: 4,
    group: 'main',
    description: 'Test scenarios',
  },
  {
    id: 'database',
    label: 'Database',
    icon: 'database',
    group: 'main',
    description: 'Database viewer',
  },
  {
    id: 'metrics',
    label: 'Metrics',
    icon: 'metrics',
    group: 'utility',
    description: 'Performance metrics',
  },
  {
    id: 'logs',
    label: 'Logs & Errors',
    icon: 'logs',
    group: 'utility',
    description: 'Error tracking',
  },
  {
    id: 'activity',
    label: 'Activity',
    icon: 'activity',
    group: 'utility',
    description: 'Recent activity',
  },
  {
    id: 'settings',
    label: 'Settings',
    icon: 'settings',
    group: 'utility',
    description: 'Configuration',
  },
];

/** ADMIN categories - Business management */
export const ADMIN_CATEGORIES: CategoryData[] = [
  {
    id: 'overview',
    label: 'Tableau de bord',
    icon: 'overview',
    group: 'main',
    description: "Vue d'ensemble",
  },
  {
    id: 'database',
    label: 'Gestion Menu',
    icon: 'database',
    group: 'main',
    description: 'Plats & catégories',
  },
  {
    id: 'test-automatics',
    label: 'Menu Personnalisé',
    icon: 'tests',
    group: 'main',
    description: 'Assistant IA menus',
  },
  {
    id: 'activity',
    label: 'Commandes',
    icon: 'activity',
    group: 'main',
    description: 'Suivi commandes',
  },
  { id: 'logs', label: 'Tickets', icon: 'logs', group: 'main', description: 'Support & tickets' },
  {
    id: 'metrics',
    label: 'Statistiques',
    icon: 'metrics',
    group: 'utility',
    description: 'Chiffres clés',
  },
  {
    id: 'settings',
    label: 'Paramètres',
    icon: 'settings',
    group: 'utility',
    description: 'Configuration',
  },
];

/** EMPLOYEE categories - Daily operations */
export const EMPLOYEE_CATEGORIES: CategoryData[] = [
  {
    id: 'overview',
    label: 'Mon Espace',
    icon: 'overview',
    group: 'main',
    description: "Vue d'ensemble",
  },
  {
    id: 'activity',
    label: 'Commandes',
    icon: 'activity',
    group: 'main',
    description: 'Commandes en cours',
  },
  {
    id: 'database',
    label: 'Menus',
    icon: 'database',
    group: 'main',
    description: 'Menus & plats',
  },
  { id: 'scenarios', label: 'Tâches', icon: 'scenarios', group: 'main', description: 'Mes tâches' },
  {
    id: 'settings',
    label: 'Profil',
    icon: 'settings',
    group: 'utility',
    description: 'Mon profil',
  },
];

/** CLIENT categories - Customer dashboard */
export const CLIENT_CATEGORIES: CategoryData[] = [
  {
    id: 'overview',
    label: 'Mon Espace',
    icon: 'overview',
    group: 'main',
    description: 'Tableau de bord',
  },
  {
    id: 'activity',
    label: 'Mes Commandes',
    icon: 'activity',
    group: 'main',
    description: 'Historique & suivi',
  },
  {
    id: 'metrics',
    label: 'Fidélité',
    icon: 'metrics',
    group: 'main',
    description: 'Points & récompenses',
  },
  { id: 'logs', label: 'Support', icon: 'logs', group: 'main', description: 'Aide & réclamations' },
  {
    id: 'scenarios',
    label: 'Mes Avis',
    icon: 'scenarios',
    group: 'main',
    description: 'Évaluations',
  },
  {
    id: 'settings',
    label: 'Mon Profil',
    icon: 'settings',
    group: 'utility',
    description: 'Informations personnelles',
  },
];

/** Get categories for a specific role view */
export function getCategoriesForRole(role: RoleView): CategoryData[] {
  switch (role) {
    case 'admin':
      return ADMIN_CATEGORIES;
    case 'employee':
      return EMPLOYEE_CATEGORIES;
    case 'client':
      return CLIENT_CATEGORIES;
    default:
      return DEV_CATEGORIES;
  }
}

/** Get default category for a role */
export function getDefaultCategory(_role: RoleView): TestCategory {
  return 'overview';
}

/** Legacy export for backward compatibility */
export const CATEGORIES = DEV_CATEGORIES;

export const DEFAULT_METRICS = {
  responseTime: { avgMs: 145, trend: 'down' as const, changePercent: 12 },
  errorRate: { errorPercent: 0.8, trend: 'stable' as const },
  dbLatency: { avgMs: 23, trend: 'up' as const, changePercent: 5 },
  coverage: { coveragePercent: 78, trend: 'up' as const, changePercent: 3 },
};
