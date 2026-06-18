/**
 * Database Service - Real CRUD operations for PostgreSQL/Supabase tables
 * Connects to the backend CRUD API (/api/crud/*)
 * Schema is fetched dynamically from the backend (Prisma DMMF)
 */

import { apiRequest } from '../../services/api';
import type { TableRecord, TableMeta, FilterConfig, PaginationState } from './types';

const BASE = '/api/crud';

/** Map model names to CRUD API endpoints */
const MODEL_TO_ENDPOINT: Record<string, string> = {
  User: 'users',
  Role: 'roles',
  Order: 'orders',
  Menu: 'menus',
  MenuImage: 'menu-images',
  MenuDish: 'menu-dishes',
  Ingredient: 'ingredients',
  MenuIngredient: 'menu-ingredients',
  DishIngredient: 'dish-ingredients',
  DishAllergen: 'dish-allergens',
  Diet: 'diets',
  Theme: 'themes',
  Dish: 'dishes',
  Allergen: 'allergens',
  WorkingHours: 'working-hours',
};

/** Fields that contain sensitive data — shown masked in the table */
export const SENSITIVE_FIELDS = new Set([
  'password',
  'password_hash',
  'access_token',
  'refresh_token',
  'token',
  'secret',
  'api_key',
]);

function logDatabaseDebug(message: string, ...args: unknown[]): void {
  if (import.meta.env.DEV) {
    console.debug(message, ...args);
  }
}

function logDatabaseWarning(message: string, error?: unknown): void {
  if (import.meta.env.DEV) {
    console.warn(message, error);
  }
}

/** Schema column from backend */
interface SchemaColumn {
  name: string;
  type: string;
  isId?: boolean;
  isRequired?: boolean;
  isList?: boolean;
  isRelation?: boolean;
  isReadOnly?: boolean;
}

/** Schema model from backend */
interface SchemaModel {
  name: string;
  columns: SchemaColumn[];
  primaryKey?: string[];
  canCreate?: boolean;
  canUpdate?: boolean;
  canDelete?: boolean;
}

export class DatabaseService {
  /** Fetch database schema from backend (Prisma DMMF) */
  static async getSchema(): Promise<SchemaModel[]> {
    try {
      logDatabaseDebug('[DatabaseService] Fetching schema from', `${BASE}/schema`);
      const response = await apiRequest<{ data?: SchemaModel[] } | SchemaModel[]>(`${BASE}/schema`);
      logDatabaseDebug('[DatabaseService] Raw schema response:', response);

      // Handle wrapped response { success, data } or direct array
      if (Array.isArray(response)) {
        logDatabaseDebug('[DatabaseService] Response is array with', response.length, 'items');
        return response;
      }
      const data = response.data || [];
      logDatabaseDebug('[DatabaseService] Extracted data with', data.length, 'items');
      return data;
    } catch (error) {
      logDatabaseWarning('[DatabaseService] Failed to fetch schema:', error);
      return [];
    }
  }

  /** Fetch row counts for all tables */
  static async getCounts(): Promise<Record<string, number>> {
    try {
      logDatabaseDebug('[DatabaseService] Fetching counts from', `${BASE}/counts`);
      const response = await apiRequest<unknown>(`${BASE}/counts`);
      logDatabaseDebug('[DatabaseService] Raw counts response:', response);

      // Handle wrapped response { success, data } or direct object
      if (isWrappedCountsResponse(response)) {
        return response.data ?? {};
      }
      if (isNumberRecord(response)) {
        return response;
      }
      return {};
    } catch (error) {
      logDatabaseWarning('[DatabaseService] Failed to fetch counts:', error);
      return {};
    }
  }

  /** Convert schema to TableMeta format with real counts */
  static async getTables(): Promise<TableMeta[]> {
    // Fetch schema and counts in parallel
    const [schema, counts] = await Promise.all([this.getSchema(), this.getCounts()]);
    logDatabaseDebug('[DatabaseService] Schema loaded:', schema.length, 'tables');
    logDatabaseDebug('[DatabaseService] Counts loaded:', counts);

    const tables = schema
      .filter((model) => MODEL_TO_ENDPOINT[model.name]) // Only include models with endpoints
      .map((model) => ({
        name: model.name,
        columns: model.columns
          .filter((col) => !col.isRelation && !col.isList) // Exclude relations
          .map((col) => ({
            name: col.name,
            type: col.type.toLowerCase(),
            nullable: !col.isRequired,
            isPrimary: col.isId ?? false,
            isReadOnly: col.isReadOnly ?? false,
          })),
        primaryKey: model.primaryKey || model.columns.filter((col) => col.isId).map((col) => col.name),
        canCreate: model.canCreate ?? true,
        canUpdate: model.canUpdate ?? true,
        canDelete: model.canDelete ?? true,
        rowCount: counts[model.name] || 0,
      }));

    logDatabaseDebug(
      '[DatabaseService] Tables with endpoints:',
      tables.map((t) => `${t.name}(${t.rowCount})`),
    );
    return tables;
  }

  /** Fetch records with filters and pagination from real CRUD API */
  static async getRecords(
    table: string,
    filters: FilterConfig[],
    pagination: PaginationState,
  ): Promise<{ data: TableRecord[]; total: number }> {
    const endpoint = MODEL_TO_ENDPOINT[table];
    if (!endpoint) {
      logDatabaseWarning(`No endpoint for table: ${table}`);
      return { data: [], total: 0 };
    }

    const params = this.buildQueryParams(filters, pagination);
    const queryString = params ? `?${params}` : '';
    const url = `${BASE}/${endpoint}${queryString}`;

    try {
      type RecordsResponse =
        | TableRecord[]
        | {
            data?: TableRecord[] | { data?: TableRecord[]; total?: number; meta?: { total?: number } };
            total?: number;
          };
      const response = await apiRequest<RecordsResponse>(url);
      logDatabaseDebug(`[DatabaseService] Response for ${table}:`, response);

      // Handle various response formats:
      // 1. Wrapped: { success, data: { data: [], total } }
      // 2. Wrapped array: { success, data: [] }
      // 3. Direct paginated: { data: [], total }
      // 4. Direct array: []

      if (Array.isArray(response)) {
        return { data: response, total: response.length };
      }

      // Check if data is the inner paginated object
      if (response.data && typeof response.data === 'object' && !Array.isArray(response.data)) {
        const inner = response.data;
        if (inner.data) {
          return { data: inner.data, total: inner.total || inner.meta?.total || inner.data.length };
        }
      }

      // Check if data is an array directly
      if (Array.isArray(response.data)) {
        return { data: response.data, total: response.total || response.data.length };
      }

      return { data: [], total: 0 };
    } catch (error) {
      logDatabaseWarning(`Error fetching ${table}:`, error);
      return { data: [], total: 0 };
    }
  }

  /** Create a new record */
  static async create(table: string, data: Partial<TableRecord>): Promise<TableRecord> {
    const endpoint = MODEL_TO_ENDPOINT[table];
    if (!endpoint) throw new Error(`No endpoint for table: ${table}`);
    return apiRequest<TableRecord>(`${BASE}/${endpoint}`, {
      method: 'POST',
      body: data,
    });
  }

  /** Update an existing record */
  static async update(table: string, key: string, data: Partial<TableRecord>): Promise<TableRecord> {
    const endpoint = MODEL_TO_ENDPOINT[table];
    if (!endpoint) throw new Error(`No endpoint for table: ${table}`);
    return apiRequest<TableRecord>(`${BASE}/${endpoint}/${key}`, {
      method: 'PUT',
      body: data,
    });
  }

  /** Delete a record */
  static async delete(table: string, key: string): Promise<void> {
    const endpoint = MODEL_TO_ENDPOINT[table];
    if (!endpoint) throw new Error(`No endpoint for table: ${table}`);
    await apiRequest(`${BASE}/${endpoint}/${key}`, { method: 'DELETE' });
  }

  /** Build query string from filters and pagination */
  private static buildQueryParams(
    filters: FilterConfig[],
    { page, pageSize }: PaginationState,
  ): string {
    const params = new URLSearchParams();
    params.set('page', String(page));
    params.set('limit', String(pageSize));

    // Build search param from contains filters
    const searchFilter = filters.find((f) => f.operator === 'contains');
    if (searchFilter) {
      params.set('search', String(searchFilter.value));
    }

    return params.toString();
  }

  // ============================================================
  // SCHEMA MODIFICATION - Create tables and columns
  // ============================================================

  /** Create a new table with columns */
  static async createTable(
    tableName: string,
    columns: Array<{
      name: string;
      type: string;
      nullable: boolean;
      defaultValue?: string | null;
      isPrimary?: boolean;
      isUnique?: boolean;
      foreignKey?: { table: string; column: string } | null;
    }>,
  ): Promise<{ success: boolean; message: string }> {
    try {
      logDatabaseDebug('[DatabaseService] Creating table:', tableName, columns);
      const response = await apiRequest<{ success: boolean; message: string }>(`${BASE}/schema/table`, {
        method: 'POST',
        body: { tableName, columns },
      });
      logDatabaseDebug('[DatabaseService] Create table response:', response);
      return response;
    } catch (error) {
      logDatabaseWarning('[DatabaseService] Failed to create table:', error);
      throw error;
    }
  }

  /** Add a column to an existing table */
  static async addColumn(
    tableName: string,
    column: {
      name: string;
      type: string;
      nullable: boolean;
      defaultValue?: string | null;
      isUnique?: boolean;
      foreignKey?: { table: string; column: string } | null;
    },
  ): Promise<{ success: boolean; message: string }> {
    try {
      logDatabaseDebug('[DatabaseService] Adding column to', tableName, ':', column);
      const response = await apiRequest<{ success: boolean; message: string }>(`${BASE}/schema/column`, {
        method: 'POST',
        body: { tableName, column },
      });
      logDatabaseDebug('[DatabaseService] Add column response:', response);
      return response;
    } catch (error) {
      logDatabaseWarning('[DatabaseService] Failed to add column:', error);
      throw error;
    }
  }

  /** Get all tables from PostgreSQL (including dynamically created) */
  static async getAllTables(): Promise<string[]> {
    try {
      const response = await apiRequest<string[] | { data: string[] }>(`${BASE}/schema/tables`);
      if (Array.isArray(response)) {
        return response;
      }
      return response.data || [];
    } catch (error) {
      logDatabaseWarning('[DatabaseService] Failed to get all tables:', error);
      return [];
    }
  }

  /** Get full database schema from PostgreSQL */
  static async getFullSchema(): Promise<
    Array<{
      name: string;
      columns: Array<{
        name: string;
        type: string;
        isNullable: boolean;
        defaultValue: string | null;
        isPrimaryKey: boolean;
      }>;
    }>
  > {
    type FullSchemaResult = Array<{
      name: string;
      columns: Array<{
        name: string;
        type: string;
        isNullable: boolean;
        defaultValue: string | null;
        isPrimaryKey: boolean;
      }>;
    }>;
    try {
      const response = await apiRequest<FullSchemaResult | { data?: FullSchemaResult }>(
        `${BASE}/schema/full`,
      );
      if (Array.isArray(response)) {
        return response;
      }
      return response.data || [];
    } catch (error) {
      logDatabaseWarning('[DatabaseService] Failed to get full schema:', error);
      return [];
    }
  }

  /** Get foreign key relationships */
  static async getForeignKeys(): Promise<
    Array<{
      tableName: string;
      columnName: string;
      referencedTable: string;
      referencedColumn: string;
    }>
  > {
    type ForeignKeyResult = Array<{
      tableName: string;
      columnName: string;
      referencedTable: string;
      referencedColumn: string;
    }>;
    try {
      const response = await apiRequest<ForeignKeyResult | { data?: ForeignKeyResult }>(
        `${BASE}/schema/foreign-keys`,
      );
      if (Array.isArray(response)) {
        return response;
      }
      return response.data || [];
    } catch (error) {
      logDatabaseWarning('[DatabaseService] Failed to get foreign keys:', error);
      return [];
    }
  }
}

function isWrappedCountsResponse(value: unknown): value is { data?: Record<string, number> } {
  return typeof value === 'object' && value !== null && 'data' in value && isNumberRecord(value.data);
}

function isNumberRecord(value: unknown): value is Record<string, number> {
  return (
    typeof value === 'object' &&
    value !== null &&
    Object.values(value).every((entry) => typeof entry === 'number')
  );
}
