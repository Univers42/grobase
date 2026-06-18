/**
 * useDatabase - State management hook for database viewer
 * Handles table loading, record fetching, search, and pagination
 */

import { useState, useCallback, useEffect, useRef } from 'react';
import { DatabaseService } from './DatabaseService';
import type { FilterConfig, DatabaseState } from './types';

const DEFAULT_PAGE_SIZE = 20;

export function useDatabase() {
  const [state, setState] = useState<DatabaseState>({
    tables: [],
    activeTable: null,
    records: [],
    filters: [],
    pagination: { page: 1, pageSize: DEFAULT_PAGE_SIZE, total: 0 },
    loading: false,
    error: null,
  });

  // Separate search state to avoid filter conflicts
  const [searchTerm, setSearchTerm] = useState('');
  const searchTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const abortControllerRef = useRef<AbortController | null>(null);

  const setLoading = (loading: boolean) => setState((s) => ({ ...s, loading }));

  const loadTables = useCallback(async () => {
    setLoading(true);
    setState((s) => ({ ...s, error: null }));
    try {
      const tables = await DatabaseService.getTables();
      setState((s) => ({ ...s, tables, loading: false }));
    } catch (e) {
      const error = e instanceof Error ? e.message : 'Failed to load tables';
      setState((s) => ({ ...s, loading: false, error }));
    }
  }, []);

  // Auto-load tables on mount
  useEffect(() => {
    loadTables();
  }, [loadTables]);

  // Load records with search term
  const loadRecords = useCallback(
    async (
      table: string,
      search: string,
      pagination: { page: number; pageSize: number; total: number },
    ) => {
      // Cancel previous request
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }
      abortControllerRef.current = new AbortController();

      setLoading(true);
      try {
        // Build filters array with search
        const filters: FilterConfig[] = search.trim()
          ? [{ column: '_search', operator: 'contains', value: search.trim() }]
          : [];

        const { data, total } = await DatabaseService.getRecords(table, filters, pagination);
        setState((s) => ({
          ...s,
          records: data,
          pagination: { ...s.pagination, total },
          filters,
          loading: false,
        }));
      } catch (e) {
        // Ignore abort errors
        if (e instanceof Error && e.name === 'AbortError') return;
        setLoading(false);
      }
    },
    [],
  );

  const selectTable = useCallback(
    async (table: string) => {
      // Clear search when switching tables
      setSearchTerm('');
      const newPagination = { page: 1, pageSize: DEFAULT_PAGE_SIZE, total: 0 };
      setState((s) => ({
        ...s,
        activeTable: table,
        pagination: newPagination,
        filters: [],
        records: [],
      }));
      await loadRecords(table, '', newPagination);
    },
    [loadRecords],
  );

  // Debounced search handler
  const handleSearch = useCallback(
    (term: string) => {
      setSearchTerm(term);

      // Clear previous timeout
      if (searchTimeoutRef.current) {
        clearTimeout(searchTimeoutRef.current);
      }

      // Debounce the actual search
      searchTimeoutRef.current = setTimeout(() => {
        if (state.activeTable) {
          loadRecords(state.activeTable, term, { ...state.pagination, page: 1 });
        }
      }, 400);
    },
    [state.activeTable, state.pagination, loadRecords],
  );

  // Clear search
  const clearSearch = useCallback(() => {
    setSearchTerm('');
    if (searchTimeoutRef.current) {
      clearTimeout(searchTimeoutRef.current);
    }
    if (state.activeTable) {
      loadRecords(state.activeTable, '', { ...state.pagination, page: 1 });
    }
  }, [state.activeTable, state.pagination, loadRecords]);

  const setPage = useCallback(
    (page: number) => {
      if (!state.activeTable) return;
      const newPagination = { ...state.pagination, page };
      setState((s) => ({ ...s, pagination: newPagination }));
      loadRecords(state.activeTable, searchTerm, newPagination);
    },
    [state.activeTable, state.pagination, searchTerm, loadRecords],
  );

  // Refresh current table data
  const refresh = useCallback(() => {
    if (state.activeTable) {
      loadRecords(state.activeTable, searchTerm, state.pagination);
    }
  }, [state.activeTable, searchTerm, state.pagination, loadRecords]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (searchTimeoutRef.current) clearTimeout(searchTimeoutRef.current);
      if (abortControllerRef.current) abortControllerRef.current.abort();
    };
  }, []);

  return {
    ...state,
    searchTerm,
    loadTables,
    selectTable,
    setPage,
    handleSearch,
    clearSearch,
    refresh,
  };
}
