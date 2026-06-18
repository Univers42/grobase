/**
 * useMenus Hook
 * React hook for fetching and managing menu data from the API
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import * as menuService from './menus';
import type { Menu, MenuFilters, PaginationMeta, Theme, Diet } from './menus';

export interface UseMenusState {
  menus: Menu[];
  meta: PaginationMeta | null;
  themes: Theme[];
  diets: Diet[];
  isLoading: boolean;
  error: string | null;
}

export interface UseMenusActions {
  fetchMenus: (filters?: MenuFilters) => Promise<void>;
  fetchThemes: () => Promise<void>;
  fetchDiets: () => Promise<void>;
  refetch: () => Promise<void>;
}

export interface UseMenusResult extends UseMenusState, UseMenusActions {}

function logMenuWarning(message: string, error: unknown) {
  if (import.meta.env.DEV) {
    console.warn(message, error);
  }
}

export function useMenus(initialFilters: MenuFilters = {}, initialDelayMs = 0): UseMenusResult {
  const [menus, setMenus] = useState<Menu[]>([]);
  const [meta, setMeta] = useState<PaginationMeta | null>(null);
  const [themes, setThemes] = useState<Theme[]>([]);
  const [diets, setDiets] = useState<Diet[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Use ref for filters to avoid re-creating callbacks on every filter change
  const filtersRef = useRef<MenuFilters>(initialFilters);

  const fetchMenus = useCallback(async (newFilters?: MenuFilters) => {
    if (newFilters) {
      filtersRef.current = newFilters;
    }

    setIsLoading(true);
    setError(null);

    try {
      const result = await menuService.getMenus(filtersRef.current);
      setMenus(result.menus);
      setMeta(result.meta);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to fetch menus');
      logMenuWarning('Error fetching menus:', e);
    } finally {
      setIsLoading(false);
    }
  }, []);

  const fetchThemes = useCallback(async () => {
    try {
      const result = await menuService.getThemes();
      setThemes(result);
    } catch (e) {
      logMenuWarning('Error fetching themes:', e);
    }
  }, []);

  const fetchDiets = useCallback(async () => {
    try {
      const result = await menuService.getDiets();
      setDiets(result);
    } catch (e) {
      logMenuWarning('Error fetching diets:', e);
    }
  }, []);

  const refetch = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const menuResult = await menuService.getMenus(filtersRef.current);
      setMenus(menuResult.menus);
      setMeta(menuResult.meta);

      globalThis.setTimeout(() => {
        void Promise.all([
          menuService
            .getThemes()
            .then(setThemes)
            .catch((e) => logMenuWarning('Error fetching themes:', e)),
          menuService
            .getDiets()
            .then(setDiets)
            .catch((e) => logMenuWarning('Error fetching diets:', e)),
        ]);
      }, 2500);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to fetch menus');
      logMenuWarning('Error fetching menus:', e);
    } finally {
      setIsLoading(false);
    }
  }, []);

  // Initial fetch — stable refetch reference, no re-runs
  useEffect(() => {
    const timer = globalThis.setTimeout(refetch, initialDelayMs);
    return () => globalThis.clearTimeout(timer);
  }, [initialDelayMs, refetch]);

  return {
    menus,
    meta,
    themes,
    diets,
    isLoading,
    error,
    fetchMenus,
    fetchThemes,
    fetchDiets,
    refetch,
  };
}

// Re-export types for convenience
export type { Menu, MenuFilters, PaginationMeta, Theme, Diet } from './menus';
