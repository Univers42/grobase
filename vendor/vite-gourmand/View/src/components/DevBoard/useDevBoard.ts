/**
 * useDevBoard - State management hook for DevBoard
 * Handles category selection, sidebar toggle, settings, and refresh
 */

import { useState, useCallback } from 'react';
import type { DevBoardState } from './types';
import type { TestCategory } from '../features/qa/sidebar';

export function useDevBoard() {
  const [state, setState] = useState<DevBoardState>({
    activeCategory: 'overview',
    viewMode: 'grid',
    isSidebarCollapsed: false,
  });

  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [lastRefresh, setLastRefresh] = useState<Date>(new Date());

  const selectCategory = useCallback((category: TestCategory) => {
    setState((prev) => ({ ...prev, activeCategory: category }));
  }, []);

  const toggleSidebar = useCallback(() => {
    setState((prev) => ({ ...prev, isSidebarCollapsed: !prev.isSidebarCollapsed }));
  }, []);

  const setViewMode = useCallback((mode: 'grid' | 'list') => {
    setState((prev) => ({ ...prev, viewMode: mode }));
  }, []);

  const openSettings = useCallback(() => {
    setIsSettingsOpen(true);
  }, []);

  const closeSettings = useCallback(() => {
    setIsSettingsOpen(false);
  }, []);

  const refresh = useCallback(async () => {
    setIsRefreshing(true);
    // Simulate API call
    await new Promise((resolve) => setTimeout(resolve, 800));
    setLastRefresh(new Date());
    setIsRefreshing(false);
  }, []);

  return {
    ...state,
    isSettingsOpen,
    isRefreshing,
    lastRefresh,
    selectCategory,
    toggleSidebar,
    setViewMode,
    openSettings,
    closeSettings,
    refresh,
  };
}
