import { useState, useCallback, useRef } from 'react';

interface PaginationOptions {
  initialPage?: number;
  pageSize?: number;
}

interface PaginationResult<T> {
  data: T[];
  page: number;
  pageSize: number;
  hasMore: boolean;
  loading: boolean;
  error: string | null;
  loadMore: () => Promise<void>;
  refresh: () => Promise<void>;
  reset: () => void;
}

/**
 * Hook for paginated data fetching
 */
export function usePagination<T>(
  fetchFn: (page: number, pageSize: number) => Promise<T[]>,
  options: PaginationOptions = {},
): PaginationResult<T> {
  const { initialPage = 1, pageSize = 20 } = options;

  const [data, setData] = useState<T[]>([]);
  const [page, setPage] = useState(initialPage);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const loadingRef = useRef(false);

  const loadMore = useCallback(async () => {
    if (loadingRef.current || !hasMore) return;

    loadingRef.current = true;
    setLoading(true);
    setError(null);

    try {
      const newItems = await fetchFn(page, pageSize);
      setData((prev) => [...prev, ...newItems]);
      setHasMore(newItems.length === pageSize);
      setPage((prev) => prev + 1);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
      loadingRef.current = false;
    }
  }, [fetchFn, page, pageSize, hasMore]);

  const refresh = useCallback(async () => {
    setPage(initialPage);
    setData([]);
    setHasMore(true);
    loadingRef.current = false;

    setLoading(true);
    setError(null);

    try {
      const newItems = await fetchFn(initialPage, pageSize);
      setData(newItems);
      setHasMore(newItems.length === pageSize);
      setPage(initialPage + 1);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [fetchFn, initialPage, pageSize]);

  const reset = useCallback(() => {
    setData([]);
    setPage(initialPage);
    setHasMore(true);
    setLoading(false);
    setError(null);
    loadingRef.current = false;
  }, [initialPage]);

  return {
    data,
    page,
    pageSize,
    hasMore,
    loading,
    error,
    loadMore,
    refresh,
    reset,
  };
}
