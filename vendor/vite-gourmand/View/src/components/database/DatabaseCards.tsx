/**
 * DatabaseCards - Card-based view for mobile database browsing
 * Notion-like cards with field emphasis
 */

import type { TableColumn, TableRecord } from './types';
import { getRecordKey, getRecordLabel } from './recordKey';
import './DatabaseCards.css';

interface Props {
  columns: TableColumn[];
  records: TableRecord[];
  onEdit: (record: TableRecord) => void;
  onDelete: (record: TableRecord) => void;
  canUpdate?: boolean;
  canDelete?: boolean;
}

export function DatabaseCards({
  columns,
  records,
  onEdit,
  onDelete,
  canUpdate = true,
  canDelete = true,
}: Readonly<Props>) {
  if (records.length === 0) {
    return <EmptyState />;
  }

  return (
    <div className="db-cards">
      {records.map((record) => (
        <RecordCard
          key={getRecordKey(record, columns)}
          record={record}
          columns={columns}
          canUpdate={canUpdate}
          canDelete={canDelete}
          onEdit={() => onEdit(record)}
          onDelete={() => onDelete(record)}
        />
      ))}
    </div>
  );
}

function RecordCard({
  record,
  columns,
  canUpdate,
  canDelete,
  onEdit,
  onDelete,
}: Readonly<{
  record: TableRecord;
  columns: TableColumn[];
  canUpdate: boolean;
  canDelete: boolean;
  onEdit: () => void;
  onDelete: () => void;
}>) {
  const titleField = findTitleField(columns, record);
  const displayFields = columns.filter((c) => !c.isPrimary).slice(0, 4);

  return (
    <article className="db-card">
      <header className="db-card-header">
        <span className="db-card-id">{getRecordLabel(record, columns)}</span>
        {titleField && <h3 className="db-card-title">{titleField}</h3>}
      </header>
      <div className="db-card-fields">
        {displayFields.map((col) => (
          <FieldDisplay key={col.name} column={col} value={record[col.name]} />
        ))}
      </div>
      {(canUpdate || canDelete) && (
        <CardActions
          onEdit={onEdit}
          onDelete={onDelete}
          canUpdate={canUpdate}
          canDelete={canDelete}
        />
      )}
    </article>
  );
}

function FieldDisplay({ column, value }: Readonly<{ column: TableColumn; value: unknown }>) {
  return (
    <div className="db-card-field">
      <span className="db-card-label">{column.name}</span>
      <span className={`db-card-value ${getValueClass(column, value)}`}>
        {formatValue(value, column)}
      </span>
    </div>
  );
}

function CardActions({
  onEdit,
  onDelete,
  canUpdate,
  canDelete,
}: Readonly<{
  onEdit: () => void;
  onDelete: () => void;
  canUpdate: boolean;
  canDelete: boolean;
}>) {
  return (
    <footer className="db-card-actions">
      {canUpdate && (
        <button className="db-card-btn db-card-btn--edit" onClick={onEdit}>
          ✏️ Edit
        </button>
      )}
      {canDelete && (
        <button className="db-card-btn db-card-btn--delete" onClick={onDelete}>
          🗑️
        </button>
      )}
    </footer>
  );
}

function EmptyState() {
  return (
    <div className="db-cards-empty">
      <span className="db-cards-empty-icon">📭</span>
      <p>No records found</p>
    </div>
  );
}

/* === Helpers === */
function findTitleField(columns: TableColumn[], record: TableRecord): string | null {
  const nameFields = new Set(['name', 'title', 'label', 'email', 'username']);
  const titleCol = columns.find((c) => nameFields.has(c.name.toLowerCase()));
  if (!titleCol) return null;
  const value = record[titleCol.name];
  if (value === null || value === undefined) return '';
  if (typeof value === 'object') return JSON.stringify(value);
  return formatPrimitiveValue(value);
}

function getValueClass(col: TableColumn, value: unknown): string {
  if (value === null || value === undefined) return 'db-card-value--null';
  if (typeof value === 'boolean') return value ? 'db-card-value--true' : 'db-card-value--false';
  if (col.type.includes('Int') || col.type === 'Float') return 'db-card-value--number';
  return '';
}

function formatValue(value: unknown, col: TableColumn): string {
  if (value === null || value === undefined) return '—';
  if (typeof value === 'boolean') return value ? '✓ Yes' : '✗ No';
  if (value instanceof Date) return value.toLocaleDateString();
  if (typeof value === 'string' && col.type === 'DateTime') {
    return new Date(value).toLocaleString();
  }
  if (typeof value === 'object') return JSON.stringify(value);
  const str = formatPrimitiveValue(value);
  return str.length > 50 ? str.slice(0, 47) + '...' : str;
}

function formatPrimitiveValue(value: unknown): string {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
    return value.toString();
  }
  if (typeof value === 'symbol') return value.description ?? '';
  return JSON.stringify(value) ?? '';
}
