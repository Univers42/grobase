/**
 * Table Selector - Dropdown to select database table
 */

import type { TableMeta } from './types';
import './TableSelector.css';

interface Props {
  tables: TableMeta[];
  active: string | null;
  onSelect: (table: string) => void;
}

export function TableSelector({ tables, active, onSelect }: Readonly<Props>) {
  return (
    <div className="table-selector">
      <label htmlFor="table-select">Table:</label>
      <select id="table-select" value={active || ''} onChange={(e) => onSelect(e.target.value)}>
        <option value="">— Sélectionner —</option>
        {tables.map((t) => (
          <option key={t.name} value={t.name}>
            {t.name} ({t.rowCount})
          </option>
        ))}
      </select>
    </div>
  );
}
