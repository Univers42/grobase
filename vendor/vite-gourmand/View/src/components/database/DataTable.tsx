/**
 * Data Table - Modern responsive table with actions
 */

import type { TableRecord, TableColumn } from './types';
import { getRecordKey } from './recordKey';
import './DataTable.css';

interface Props {
  columns: TableColumn[];
  records: TableRecord[];
  onEdit: (record: TableRecord) => void;
  onDelete: (record: TableRecord) => void;
  canUpdate?: boolean;
  canDelete?: boolean;
}

export function DataTable({
  columns,
  records,
  onEdit,
  onDelete,
  canUpdate = true,
  canDelete = true,
}: Readonly<Props>) {
  if (records.length === 0) {
    return <div className="data-table-empty">Aucun enregistrement trouvé</div>;
  }

  const hasActions = canUpdate || canDelete;

  return (
    <div className="data-table-wrapper">
      <table className="data-table">
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.name}>
                {c.name}
                {c.isPrimary && <span className="pk-badge">PK</span>}
                {c.isReadOnly && <span className="readonly-badge">RO</span>}
              </th>
            ))}
            {hasActions && <th>Actions</th>}
          </tr>
        </thead>
        <tbody>
          {records.map((r) => (
            <tr key={getRecordKey(r, columns)}>
              {columns.map((c) => {
                const cellClass = getCellClass(c, r[c.name]);
                return (
                  <td key={c.name} className={cellClass} title={formatCellTitle(r[c.name], c)}>
                    {formatCell(r[c.name], c)}
                  </td>
                );
              })}
              {hasActions && (
                <td className="data-table-actions">
                  {canUpdate && (
                    <button onClick={() => onEdit(r)} title="Modifier">
                      ✏️
                    </button>
                  )}
                  {canDelete && (
                    <button className="btn-delete" onClick={() => onDelete(r)} title="Supprimer">
                      🗑️
                    </button>
                  )}
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function getCellClass(col: TableColumn, value: unknown): string {
  const classes: string[] = [];
  if (col.isPrimary || col.name === 'id') classes.push('cell-id');
  if (typeof value === 'boolean' || col.type === 'boolean') {
    classes.push('cell-boolean');
    if (value === false) classes.push('false');
  }
  return classes.join(' ');
}

function formatCell(value: unknown, col: TableColumn): string {
  if (value === null || value === undefined) return '—';

  if (isSensitiveColumn(col.name)) {
    return '••••••••';
  }

  // Boolean values - handled via CSS
  if (typeof value === 'boolean' || col.type === 'boolean') return '';

  // Date values
  if (col.name.toLowerCase().includes('date') || col.name.toLowerCase().includes('at')) {
    try {
      const date = new Date(value as string);
      if (!Number.isNaN(date.getTime())) {
        return date.toLocaleDateString('fr-FR', {
          day: '2-digit',
          month: '2-digit',
          year: 'numeric',
          hour: '2-digit',
          minute: '2-digit',
        });
      }
    } catch {
      /* fall through */
    }
  }

  // Objects/Arrays - JSON preview
  if (typeof value === 'object') {
    return JSON.stringify(value).slice(0, 40) + '…';
  }

  // Default - truncate long strings
  const str = stringifyDisplayValue(value);
  return str.length > 50 ? str.slice(0, 47) + '…' : str;
}

function formatCellTitle(value: unknown, col: TableColumn): string {
  if (value === null || value === undefined || isSensitiveColumn(col.name)) return '';
  if (typeof value === 'object') return JSON.stringify(value);
  return stringifyDisplayValue(value);
}

function stringifyDisplayValue(value: unknown): string {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
    return String(value);
  }
  return JSON.stringify(value);
}

function isSensitiveColumn(name: string): boolean {
  const normalized = name.toLowerCase();
  return (
    normalized === 'password' ||
    normalized.includes('password') ||
    normalized.includes('hash') ||
    normalized.includes('token') ||
    normalized.includes('secret') ||
    normalized.includes('api_key') ||
    normalized.includes('apikey') ||
    normalized.includes('authorization') ||
    normalized.includes('credential')
  );
}
