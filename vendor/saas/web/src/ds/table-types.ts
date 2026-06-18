// table-types.ts — shared types for the Table component, kept separate so the
// header-cell helper and the table can import them without a cycle.

import type { ReactNode } from 'react';

/** SortDir is the current sort direction of a column, or none. */
export type SortDir = 'asc' | 'desc' | null;

/** Column describes one table column: how to label and render a row's cell. */
export type Column<T> = {
  key: string;
  header: string;
  sortable?: boolean;
  align?: 'left' | 'right';
  render: (row: T) => ReactNode;
};

/** SortState pairs the active column key with its direction. */
export type SortState = { key: string; dir: SortDir };
