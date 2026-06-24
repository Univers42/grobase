/**
 * Remember Me Service
 * Local storage for user preferences
 */

import type { RememberMeData } from './types';

const STORAGE_KEY = 'vg_remember_me';
const MAX_AGE_DAYS = 30;

/** Save user data for remember me */
export function saveRememberMe(data: Omit<RememberMeData, 'timestamp'>): void {
  const stored: RememberMeData = { ...data, timestamp: Date.now() };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(stored));
}

/** Get saved remember me data */
export function getRememberMe(): RememberMeData | null {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (!stored) return null;

  try {
    const data: RememberMeData = JSON.parse(stored);
    const maxAge = MAX_AGE_DAYS * 24 * 60 * 60 * 1000;

    if (Date.now() - data.timestamp > maxAge) {
      clearRememberMe();
      return null;
    }
    return data;
  } catch {
    return null;
  }
}

/** Clear remember me data */
export function clearRememberMe(): void {
  localStorage.removeItem(STORAGE_KEY);
}
