/**
 * Grid - Responsive grid layout
 * Used for arranging cards and content
 */

import './Grid.css';

type GridColumns = 1 | 2 | 3 | 4 | 'auto';

interface GridProps {
  children: React.ReactNode;
  columns?: GridColumns;
  gap?: 'sm' | 'md' | 'lg';
}

export function Grid({ children, columns = 'auto', gap = 'md' }: Readonly<GridProps>) {
  const classes = buildClasses(columns, gap);

  return <div className={classes}>{children}</div>;
}

function buildClasses(columns: GridColumns, gap: string): string {
  return ['layout-grid', `layout-grid-cols-${columns}`, `layout-grid-gap-${gap}`].join(' ');
}
