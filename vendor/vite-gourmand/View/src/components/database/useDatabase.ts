/**
 * useDatabase - State management hook for database viewer
 * Handles table loading, record fetching, search, and pagination
 */

import { useState, useCallback, useEffect, useRef } from 'react';
import { DatabaseService } from './DatabaseService';
import { subscribeTable } from '../../services/baas';
import { dbIdForTable, fetchRowByTable } from '../../services/baas-crud';
import type { FilterConfig, DatabaseState, TableRecord } from './types';

/** Match a record against an event primary key (PG numeric `id`, Mongo `_id`). */
const matchesPk = (row: TableRecord, pk: string | number): boolean =>
  String(row.id ?? row._id ?? '') === String(pk);

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

  // Patch one already-loaded record in place (no refetch → no flash).
  const applyRecord = useCallback((pk: string | number, partial: Record<string, unknown>) => {
    setState((s) => {
      const idx = s.records.findIndex((r) => matchesPk(r, pk));
      if (idx === -1) return s;
      const records = [...s.records];
      records[idx] = { ...records[idx], ...partial };
      return { ...s, records };
    });
  }, []);

  // Drop one record from the current page (delete).
  const removeRecord = useCallback((pk: string | number) => {
    setState((s) => ({ ...s, records: s.records.filter((r) => !matchesPk(r, pk)) }));
  }, []);

  // Live updates: subscribe to the active table's Grobase realtime change stream.
  // Events are change NOTIFICATIONS ({op,pk}), not rows — so re-fetch the single
  // changed row on update (in-place patch, no flash), remove on delete, refresh
  // on insert (need the new row + total).
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;
  useEffect(() => {
    const table = state.activeTable;
    if (!table) return;
    return subscribeTable(dbIdForTable(table), table, (change) => {
      if (change.pk == null) {
        refreshRef.current();
        return;
      }
      if (change.event === 'delete') {
        removeRecord(change.pk);
        return;
      }
      if (change.event === 'insert') {
        refreshRef.current();
        return;
      }
      fetchRowByTable(table, change.pk).then((row) => {
        if (row) applyRecord(change.pk as string | number, row);
      });
    });
  }, [state.activeTable, applyRecord, removeRecord]);

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
    applyRecord,
    removeRecord,
  };
}
