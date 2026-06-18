import { useState, useEffect, useCallback } from 'react';
import baas from '@/baas/client';

/**
 * Generic hook for reading a BaaS collection with optional filters.
 *
 * @param {string}  collection  — Collection / table name
 * @param {object}  [options]
 * @param {object}  [options.filters]   — { field: value } eq filters
 * @param {string}  [options.order]     — 'field.asc' or 'field.desc'
 * @param {number}  [options.limit]
 * @param {number}  [options.offset]
 * @param {string}  [options.join]      — relation name
 * @param {boolean} [options.single]    — return first item only
 * @param {boolean} [options.enabled=true]
 * @returns {{ data, loading, error, refetch }}
 */
export default function useBaasCollection(collection, options = {}) {
  const {
    filters = {},
    order,
    limit,
    offset,
    join,
    single = false,
    enabled = true,
  } = options;

  const [data, setData]       = useState(single ? null : []);
  const [loading, setLoading] = useState(true);
  const [error, setError]     = useState(null);

  // Serialise deps so useEffect re-runs on filter changes
  const depsKey = JSON.stringify({ collection, filters, order, limit, offset, join, single });

  const fetchData = useCallback(async () => {
    if (!enabled) return;
    setLoading(true);
    setError(null);

    try {
      let q = baas.collection(collection);

      // Apply eq filters
      Object.entries(filters).forEach(([k, v]) => {
        q = q.eq(k, v);
      });

      if (join)   q = q.join(join);
      if (order) {
        const [field, dir] = order.split('.');
        q = q.order(field, dir || 'asc');
      }
      if (limit  != null) q = q.limit(limit);
      if (offset != null) q = q.offset(offset);

      const result = single ? await q.single() : await q.get();
      setData(result);
    } catch (err) {
      setError(err);
    } finally {
      setLoading(false);
    }
  }, [depsKey, enabled]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  return { data, loading, error, refetch: fetchData };
}
