import type { TableColumn, TableRecord } from './types';

export function getRecordKey(record: TableRecord, columns: TableColumn[]): string {
  const primaryColumns = columns.filter((column) => column.isPrimary);

  if (primaryColumns.length === 1) {
    const key = record[primaryColumns[0].name];
    return encodeURIComponent(String(key));
  }

  const compositeKey = Object.fromEntries(
    primaryColumns.map((column) => [column.name, record[column.name]]),
  );

  return encodeURIComponent(JSON.stringify(compositeKey));
}

export function getRecordLabel(record: TableRecord, columns: TableColumn[]): string {
  const primaryColumns = columns.filter((column) => column.isPrimary);
  if (primaryColumns.length === 0) return '';

  return primaryColumns.map((column) => `${column.name}=${String(record[column.name])}`).join(', ');
}
