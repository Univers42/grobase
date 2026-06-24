// useQueryTable.ts — generic list+search+paginate+sort over a Db.list call. Keeps
// page/query/sort state and refetches on change, exposing {rows,total,loading,...}.

import { useCallback, useEffect, useMemo, useState } from 'react';
import type { Db, Row, Sort } from '../lib/db';
import { ilike } from '../lib/filters';

/** QueryTableOptions configures the table source. */
export type QueryTableOptions = { db: Db; table: string; pageSize?: number; searchColumn?: string };

/** QueryTableState is the reactive table snapshot + controls. */
export type QueryTableState = {
  rows: Row[];
  total: number;
  page: number;
  loading: boolean;
  error: string | null;
  query: string;
  refetch: () => void;
  setPage: (page: number) => void;
  setQuery: (query: string) => void;
  setSort: (sort: Sort | undefined) => void;
};

/** useQueryTable runs a paginated, searchable, sortable list query. */
export function useQueryTable({ db, table, pageSize = 20, searchColumn }: QueryTableOptions): QueryTableState {
  const [rows, setRows] = useState<Row[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [query, setQueryState] = useState('');
  const [sort, setSort] = useState<Sort | undefined>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  const filter = useMemo(
    () => (query && searchColumn ? ilike(searchColumn, query) : undefined),
    [query, searchColumn],
  );

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    Promise.all([
      db.list(table, { filter, limit: pageSize, offset: (page - 1) * pageSize, sort }),
      db.count(table, { filter }),
    ])
      .then(([r, count]) => {
        if (cancelled) return;
        setRows(r.rows);
        setTotal(count);
      })
      .catch((e: unknown) => !cancelled && setError(e instanceof Error ? e.message : 'query failed'))
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [db, table, filter, sort, page, pageSize, tick]);

  const setQuery = useCallback((q: string) => {
    setPage(1);
    setQueryState(q);
  }, []);

  return {
    rows, total, page, loading, error, query,
    refetch: () => setTick((t) => t + 1),
    setPage, setQuery, setSort,
  };
}
