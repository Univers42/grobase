// Table.tsx — an accessible sortable data table. Header cells carry scope="col"
// and aria-sort; sortable headers are buttons that cycle asc → desc on the active
// column. Generic over the row type T.

import clsx from 'clsx';
import type { Column, SortDir, SortState } from './table-types';
import { Icon } from './Icon';

/** TableProps configures the columns, rows, and optional sort control. */
export type TableProps<T> = {
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string;
  sort?: SortState;
  onSort?: (key: string, dir: SortDir) => void;
  caption?: string;
};

/** ariaSort maps a column's sort state to the WAI-ARIA aria-sort token. */
function ariaSort(active: boolean, dir: SortDir): 'ascending' | 'descending' | 'none' {
  if (!active || dir === null) return 'none';
  return dir === 'asc' ? 'ascending' : 'descending';
}

/** Table renders a sortable, screen-reader-friendly data grid. */
export function Table<T>({ columns, rows, rowKey, sort, onSort, caption }: TableProps<T>) {
  const cycle = (key: string) => {
    if (!onSort) return;
    const active = sort?.key === key;
    onSort(key, active && sort?.dir === 'asc' ? 'desc' : 'asc');
  };

  return (
    <div
      className="overflow-x-auto rounded-2xl border border-line"
      tabIndex={0}
      role="region"
      aria-label={caption ?? 'Data table'}
    >
      <table className="w-full border-collapse text-sm">
        {caption && <caption className="sr-only">{caption}</caption>}
        <thead>
          <tr className="border-b border-line text-left text-xs uppercase tracking-wide text-muted">
            {columns.map((c) => {
              const active = sort?.key === c.key;
              return (
                <th
                  key={c.key}
                  scope="col"
                  aria-sort={ariaSort(active, sort?.dir ?? null)}
                  className={clsx('px-4 py-3 font-medium', c.align === 'right' && 'text-right')}
                >
                  {c.sortable ? (
                    <button
                      type="button"
                      onClick={() => cycle(c.key)}
                      className="inline-flex items-center gap-1 hover:text-ink"
                    >
                      {c.header}
                      <Icon name={active && sort?.dir === 'desc' ? 'down' : 'up'} size={12} className={clsx(!active && 'opacity-30')} />
                    </button>
                  ) : (
                    c.header
                  )}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={rowKey(row)} className="border-b border-line/60 last:border-0 hover:bg-white/[0.02]">
              {columns.map((c) => (
                <td key={c.key} className={clsx('px-4 py-3 text-ink/90', c.align === 'right' && 'text-right tabular-nums')}>
                  {c.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
