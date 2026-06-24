/**
 * Menu Types and Fallback Data
 *
 * This file provides:
 * 1. Type definitions for menus
 * 2. Fallback static data when API is unavailable
 *
 * NOTE: Primary data should come from the API via useMenus hook.
 * This static data is only used as a fallback.
 */

export type DietaryType =
  | 'classique'
  | 'végétarien'
  | 'vegan'
  | 'sans-gluten'
  | 'sans-lactose'
  | 'halal'
  | 'casher'
  | 'bio';

export interface MenuComposition {
  entreeDishes: string[];
  mainDishes: string[];
  dessertDishes: string[];
}

export interface Menu {
  id: string;
  name: string;
  theme: string;
  description: string;
  composition?: MenuComposition;
  dietary: DietaryType[];
  minPersons: number;
  maxPersons: number;
  pricePerPerson: number;
  image: string;
  allergens: string[];
  deliveryNotes?: string;
  stockQuantity: number;
  dishes?: {
    entrees: { id: number; title: string; description: string | null; photo_url: string | null }[];
    mains: { id: number; title: string; description: string | null; photo_url: string | null }[];
    desserts: { id: number; title: string; description: string | null; photo_url: string | null }[];
  };
}

// Default fallback image
export const FALLBACK_IMAGE = '/menu-fallback-640.webp';

/**
 * Empty menus array - data comes from API
 * Use the useMenus hook to fetch real data
 */
export const menus: Menu[] = [];

/**
 * Get all themes (fallback, prefer API)
 * @deprecated Use menuService.getThemes() instead
 */
export function getAllThemes(): string[] {
  return ['Gastronomie', 'Mariage', 'Entreprise', 'Anniversaire', 'Végétarien', 'Vegan', 'Fêtes'];
}

/**
 * Get all dietary types
 */
export function getAllDietaryTypes(): DietaryType[] {
  return [
    'classique',
    'végétarien',
    'vegan',
    'sans-gluten',
    'sans-lactose',
    'halal',
    'casher',
    'bio',
  ];
}

