/**
 * CRUD Controller - Dynamic database operations for DevBoard
 * Provides allowlisted schema, counts, and CRUD operations for business tables.
 */
import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Param,
  Post,
  Put,
  Query,
  UseGuards,
} from '@nestjs/common';
import { JwtAuthGuard } from '../common/guards/jwt-auth.guard';
import { RolesGuard } from '../common/guards/roles.guard';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import type { JwtPayload } from '../common/types/request.types';
import { CrudService, PaginatedResult } from './crud.service';
import { PrismaService } from '../prisma';

/** Schema column definition */
interface SchemaColumn {
  name: string;
  type: string;
  isId?: boolean;
  isRequired?: boolean;
  isList?: boolean;
  isRelation?: boolean;
  isReadOnly?: boolean;
}

/** Schema model definition */
interface SchemaModel {
  name: string;
  columns: SchemaColumn[];
  primaryKey: string[];
  canCreate: boolean;
  canUpdate: boolean;
  canDelete: boolean;
}

interface TablePolicy {
  endpoint: string;
  modelName: string;
  schema: SchemaModel;
  primaryKey: string[];
  searchableFields: string[];
  writableFields: string[];
  sensitiveFields?: string[];
  defaultOrderBy?: Record<string, 'asc' | 'desc'>;
  custom?: 'menuDish';
}

interface PaginationOptions {
  page: number;
  limit: number;
}

interface CrudListQuery {
  page?: string;
  limit?: string;
  skip?: string;
  take?: string;
  search?: string;
  orderBy?: string;
  order?: string;
}

interface MenuDishRow {
  menu_id: number;
  dish_id: number;
  menu_title: string;
  dish_title: string;
}

type MenuDishPrisma = {
  menu: {
    findMany: (args: Record<string, unknown>) => Promise<
      Array<{
        id: number;
        title: string;
        Dish: Array<{ id: number; title: string }>;
      }>
    >;
    findUnique: (
      args: Record<string, unknown>,
    ) => Promise<{ id: number; title: string } | null>;
    update: (args: Record<string, unknown>) => Promise<unknown>;
  };
  dish: {
    findUnique: (
      args: Record<string, unknown>,
    ) => Promise<{ id: number; title: string } | null>;
  };
};

const MAX_PAGE_SIZE = 100;

const READONLY_TIMESTAMPS = new Set([
  'created_at',
  'updated_at',
  'uploaded_at',
  'last_login_at',
  'deleted_at',
]);

function model(
  name: string,
  columns: SchemaColumn[],
  options: Partial<
    Pick<SchemaModel, 'canCreate' | 'canUpdate' | 'canDelete'>
  > = {},
): SchemaModel {
  return {
    name,
    columns,
    primaryKey: columns
      .filter((column) => column.isId)
      .map((column) => column.name),
    canCreate: options.canCreate ?? true,
    canUpdate: options.canUpdate ?? true,
    canDelete: options.canDelete ?? true,
  };
}

/** Static schema definitions for Prisma 7 compatibility. */
const SCHEMA_MODELS: SchemaModel[] = [
  model(
    'User',
    [
      {
        name: 'id',
        type: 'integer',
        isId: true,
        isRequired: true,
        isReadOnly: true,
      },
      { name: 'email', type: 'string', isRequired: true },
      { name: 'first_name', type: 'string', isRequired: true },
      { name: 'last_name', type: 'string' },
      { name: 'phone_number', type: 'string' },
      { name: 'city', type: 'string' },
      { name: 'country', type: 'string' },
      { name: 'postal_code', type: 'string' },
      { name: 'role_id', type: 'integer' },
      { name: 'is_active', type: 'boolean' },
      { name: 'is_email_verified', type: 'boolean' },
      { name: 'created_at', type: 'datetime', isReadOnly: true },
      { name: 'updated_at', type: 'datetime', isReadOnly: true },
    ],
    { canCreate: false, canUpdate: false, canDelete: false },
  ),
  model(
    'Role',
    [
      {
        name: 'id',
        type: 'integer',
        isId: true,
        isRequired: true,
        isReadOnly: true,
      },
      { name: 'name', type: 'string', isRequired: true },
      { name: 'description', type: 'string' },
      { name: 'created_at', type: 'datetime', isReadOnly: true },
    ],
    { canCreate: false, canUpdate: false, canDelete: false },
  ),
  model(
    'Order',
    [
      {
        name: 'id',
        type: 'integer',
        isId: true,
        isRequired: true,
        isReadOnly: true,
      },
      { name: 'order_number', type: 'string', isRequired: true },
      { name: 'user_id', type: 'integer', isRequired: true },
      { name: 'order_date', type: 'datetime', isReadOnly: true },
      { name: 'delivery_date', type: 'date', isRequired: true },
      { name: 'delivery_hour', type: 'string' },
      { name: 'delivery_address', type: 'string' },
      { name: 'delivery_city', type: 'string' },
      { name: 'person_number', type: 'integer', isRequired: true },
      { name: 'menu_price', type: 'decimal', isRequired: true },
      { name: 'delivery_price', type: 'decimal' },
      { name: 'total_price', type: 'decimal', isRequired: true },
      { name: 'status', type: 'string' },
      { name: 'special_instructions', type: 'string' },
      { name: 'created_at', type: 'datetime', isReadOnly: true },
      { name: 'updated_at', type: 'datetime', isReadOnly: true },
    ],
    { canCreate: false, canUpdate: false, canDelete: false },
  ),
  model('Menu', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'title', type: 'string', isRequired: true },
    { name: 'description', type: 'string' },
    { name: 'conditions', type: 'string' },
    { name: 'person_min', type: 'integer', isRequired: true },
    { name: 'price_per_person', type: 'decimal', isRequired: true },
    { name: 'remaining_qty', type: 'integer' },
    { name: 'status', type: 'string' },
    { name: 'diet_id', type: 'integer' },
    { name: 'theme_id', type: 'integer' },
    { name: 'created_by', type: 'integer', isReadOnly: true },
    { name: 'is_seasonal', type: 'boolean' },
    { name: 'available_from', type: 'date' },
    { name: 'available_until', type: 'date' },
    { name: 'created_at', type: 'datetime', isReadOnly: true },
    { name: 'updated_at', type: 'datetime', isReadOnly: true },
    { name: 'published_at', type: 'datetime' },
  ]),
  model('MenuImage', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'menu_id', type: 'integer', isRequired: true },
    { name: 'image_url', type: 'string', isRequired: true },
    { name: 'alt_text', type: 'string' },
    { name: 'display_order', type: 'integer' },
    { name: 'is_primary', type: 'boolean' },
    { name: 'uploaded_at', type: 'datetime', isReadOnly: true },
  ]),
  model(
    'MenuDish',
    [
      { name: 'menu_id', type: 'integer', isId: true, isRequired: true },
      { name: 'dish_id', type: 'integer', isId: true, isRequired: true },
      { name: 'menu_title', type: 'string', isReadOnly: true },
      { name: 'dish_title', type: 'string', isReadOnly: true },
    ],
    { canUpdate: false },
  ),
  model('Dish', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'title', type: 'string', isRequired: true },
    { name: 'description', type: 'string' },
    { name: 'photo_url', type: 'string' },
    { name: 'course_type', type: 'string' },
    { name: 'created_at', type: 'datetime', isReadOnly: true },
  ]),
  model('Ingredient', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'name', type: 'string', isRequired: true },
    { name: 'unit', type: 'string' },
    { name: 'current_stock', type: 'decimal' },
    { name: 'min_stock_level', type: 'decimal' },
    { name: 'cost_per_unit', type: 'decimal' },
    { name: 'last_restocked_at', type: 'datetime' },
    { name: 'created_at', type: 'datetime', isReadOnly: true },
    { name: 'updated_at', type: 'datetime', isReadOnly: true },
  ]),
  model('MenuIngredient', [
    { name: 'menu_id', type: 'integer', isId: true, isRequired: true },
    { name: 'ingredient_id', type: 'integer', isId: true, isRequired: true },
    { name: 'quantity_per_person', type: 'decimal', isRequired: true },
  ]),
  model('DishIngredient', [
    { name: 'dish_id', type: 'integer', isId: true, isRequired: true },
    { name: 'ingredient_id', type: 'integer', isId: true, isRequired: true },
    { name: 'quantity', type: 'decimal', isRequired: true },
  ]),
  model(
    'DishAllergen',
    [
      { name: 'dish_id', type: 'integer', isId: true, isRequired: true },
      { name: 'allergen_id', type: 'integer', isId: true, isRequired: true },
    ],
    { canUpdate: false },
  ),
  model('Diet', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'name', type: 'string', isRequired: true },
    { name: 'description', type: 'string' },
    { name: 'icon_url', type: 'string' },
  ]),
  model('Theme', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'name', type: 'string', isRequired: true },
    { name: 'description', type: 'string' },
    { name: 'icon_url', type: 'string' },
  ]),
  model('Allergen', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'name', type: 'string', isRequired: true },
    { name: 'icon_url', type: 'string' },
  ]),
  model('WorkingHours', [
    {
      name: 'id',
      type: 'integer',
      isId: true,
      isRequired: true,
      isReadOnly: true,
    },
    { name: 'day', type: 'string', isRequired: true },
    { name: 'opening', type: 'string', isRequired: true },
    { name: 'closing', type: 'string', isRequired: true },
  ]),
];

const MODEL_BY_NAME = new Map(
  SCHEMA_MODELS.map((schema) => [schema.name, schema]),
);

function getSchema(name: string): SchemaModel {
  const schema = MODEL_BY_NAME.get(name);
  if (!schema) throw new Error(`Missing CRUD schema for ${name}`);
  return schema;
}

function writableFields(schema: SchemaModel): string[] {
  const hasCompositePrimaryKey = schema.primaryKey.length > 1;
  return schema.columns
    .filter((column) => {
      if (column.isReadOnly || READONLY_TIMESTAMPS.has(column.name))
        return false;
      if (column.isId && !hasCompositePrimaryKey) return false;
      return true;
    })
    .map((column) => column.name);
}

const TABLE_POLICIES: TablePolicy[] = [
  {
    endpoint: 'users',
    modelName: 'user',
    schema: getSchema('User'),
    primaryKey: ['id'],
    searchableFields: [
      'email',
      'first_name',
      'last_name',
      'city',
      'postal_code',
    ],
    writableFields: [],
    sensitiveFields: ['password'],
    defaultOrderBy: { id: 'asc' },
  },
  {
    endpoint: 'roles',
    modelName: 'role',
    schema: getSchema('Role'),
    primaryKey: ['id'],
    searchableFields: ['name', 'description'],
    writableFields: [],
    defaultOrderBy: { id: 'asc' },
  },
  {
    endpoint: 'orders',
    modelName: 'order',
    schema: getSchema('Order'),
    primaryKey: ['id'],
    searchableFields: [
      'order_number',
      'status',
      'delivery_address',
      'delivery_city',
    ],
    writableFields: [],
    defaultOrderBy: { id: 'desc' },
  },
  {
    endpoint: 'menus',
    modelName: 'menu',
    schema: getSchema('Menu'),
    primaryKey: ['id'],
    searchableFields: ['title', 'description', 'conditions', 'status'],
    writableFields: writableFields(getSchema('Menu')),
    defaultOrderBy: { id: 'desc' },
  },
  {
    endpoint: 'menu-images',
    modelName: 'menuImage',
    schema: getSchema('MenuImage'),
    primaryKey: ['id'],
    searchableFields: ['image_url', 'alt_text'],
    writableFields: writableFields(getSchema('MenuImage')),
    defaultOrderBy: { id: 'desc' },
  },
  {
    endpoint: 'menu-dishes',
    modelName: 'menuDish',
    schema: getSchema('MenuDish'),
    primaryKey: ['menu_id', 'dish_id'],
    searchableFields: ['menu_title', 'dish_title'],
    writableFields: ['menu_id', 'dish_id'],
    custom: 'menuDish',
  },
  {
    endpoint: 'dishes',
    modelName: 'dish',
    schema: getSchema('Dish'),
    primaryKey: ['id'],
    searchableFields: ['title', 'description', 'course_type'],
    writableFields: writableFields(getSchema('Dish')),
    defaultOrderBy: { id: 'desc' },
  },
  {
    endpoint: 'ingredients',
    modelName: 'ingredient',
    schema: getSchema('Ingredient'),
    primaryKey: ['id'],
    searchableFields: ['name', 'unit'],
    writableFields: writableFields(getSchema('Ingredient')),
    defaultOrderBy: { id: 'asc' },
  },
  {
    endpoint: 'menu-ingredients',
    modelName: 'menuIngredient',
    schema: getSchema('MenuIngredient'),
    primaryKey: ['menu_id', 'ingredient_id'],
    searchableFields: [],
    writableFields: writableFields(getSchema('MenuIngredient')),
  },
  {
    endpoint: 'dish-ingredients',
    modelName: 'dishIngredient',
    schema: getSchema('DishIngredient'),
    primaryKey: ['dish_id', 'ingredient_id'],
    searchableFields: [],
    writableFields: writableFields(getSchema('DishIngredient')),
  },
  {
    endpoint: 'dish-allergens',
    modelName: 'dishAllergen',
    schema: getSchema('DishAllergen'),
    primaryKey: ['dish_id', 'allergen_id'],
    searchableFields: [],
    writableFields: writableFields(getSchema('DishAllergen')),
  },
  {
    endpoint: 'diets',
    modelName: 'diet',
    schema: getSchema('Diet'),
    primaryKey: ['id'],
    searchableFields: ['name', 'description'],
    writableFields: writableFields(getSchema('Diet')),
    defaultOrderBy: { id: 'asc' },
  },
  {
    endpoint: 'themes',
    modelName: 'theme',
    schema: getSchema('Theme'),
    primaryKey: ['id'],
    searchableFields: ['name', 'description'],
    writableFields: writableFields(getSchema('Theme')),
    defaultOrderBy: { id: 'asc' },
  },
  {
    endpoint: 'allergens',
    modelName: 'allergen',
    schema: getSchema('Allergen'),
    primaryKey: ['id'],
    searchableFields: ['name'],
    writableFields: writableFields(getSchema('Allergen')),
    defaultOrderBy: { id: 'asc' },
  },
  {
    endpoint: 'working-hours',
    modelName: 'workingHours',
    schema: getSchema('WorkingHours'),
    primaryKey: ['id'],
    searchableFields: ['day', 'opening', 'closing'],
    writableFields: writableFields(getSchema('WorkingHours')),
    defaultOrderBy: { id: 'asc' },
  },
];

const POLICIES_BY_ENDPOINT = new Map(
  TABLE_POLICIES.map((policy) => [policy.endpoint, policy]),
);

@Controller('crud')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('admin', 'employee', 'employe')
export class CrudController {
  constructor(
    private readonly crudService: CrudService,
    private readonly prisma: PrismaService,
  ) {}

  /** GET /api/crud/schema */
  @Get('schema')
  getSchema(): SchemaModel[] {
    return SCHEMA_MODELS;
  }

  /** GET /api/crud/counts */
  @Get('counts')
  async getCounts(): Promise<Record<string, number>> {
    const counts: Record<string, number> = {};

    for (const policy of TABLE_POLICIES) {
      counts[policy.schema.name] = await this.countRecords(policy);
    }

    return counts;
  }

  /** GET /api/crud/:table */
  @Get(':table')
  async getRecords(
    @Param('table') table: string,
    @Query() query: CrudListQuery = {},
  ): Promise<PaginatedResult<Record<string, unknown>>> {
    const { page, limit, skip, take, search, orderBy, order } = query;
    const policy = this.getPolicy(table);
    const pagination = this.normalizePagination({ page, limit, skip, take });

    if (policy.custom === 'menuDish') {
      return this.findMenuDishes(pagination, search);
    }

    const result = await this.crudService.findAll<Record<string, unknown>>(
      policy.modelName,
      {
        page: pagination.page,
        limit: pagination.limit,
        where: search ? this.buildSearchWhere(policy, search) : {},
        orderBy: this.buildOrderBy(policy, orderBy, order),
      },
    );

    return this.sanitizePaginated(policy, result);
  }

  /** GET /api/crud/:table/:id */
  @Get(':table/:id')
  async getRecord(@Param('table') table: string, @Param('id') id: string) {
    const policy = this.getPolicy(table);

    if (policy.custom === 'menuDish') {
      return this.findMenuDish(this.parseCompositeKey(id, policy.primaryKey));
    }

    const record = await this.crudService.findOne<Record<string, unknown>>(
      policy.modelName,
      this.parseUniqueWhere(id, policy),
    );

    return this.sanitizeRecord(policy, record);
  }

  /** POST /api/crud/:table */
  @Post(':table')
  async createRecord(
    @Param('table') table: string,
    @Body() data: Record<string, unknown>,
    @CurrentUser() user: JwtPayload,
  ) {
    const policy = this.getPolicy(table);
    this.assertCanWrite(policy, 'create');

    const processed = this.processData(policy, data, 'create');
    if (policy.modelName === 'menu' && user?.sub) {
      processed.created_by = user.sub;
    }

    if (policy.custom === 'menuDish') {
      return this.createMenuDish(processed);
    }

    return this.sanitizeRecord(
      policy,
      await this.crudService.create<Record<string, unknown>>(
        policy.modelName,
        processed,
      ),
    );
  }

  /** PUT /api/crud/:table/:id */
  @Put(':table/:id')
  async updateRecord(
    @Param('table') table: string,
    @Param('id') id: string,
    @Body() data: Record<string, unknown>,
  ) {
    const policy = this.getPolicy(table);
    this.assertCanWrite(policy, 'update');

    const processed = this.processData(policy, data, 'update');
    return this.sanitizeRecord(
      policy,
      await this.crudService.update<Record<string, unknown>>(
        policy.modelName,
        this.parseUniqueWhere(id, policy),
        processed,
      ),
    );
  }

  /** DELETE /api/crud/:table/:id */
  @Delete(':table/:id')
  async deleteRecord(@Param('table') table: string, @Param('id') id: string) {
    const policy = this.getPolicy(table);
    this.assertCanWrite(policy, 'delete');

    if (policy.custom === 'menuDish') {
      return this.deleteMenuDish(this.parseCompositeKey(id, policy.primaryKey));
    }

    return this.crudService.remove(
      policy.modelName,
      this.parseUniqueWhere(id, policy),
    );
  }

  private getPolicy(endpoint: string): TablePolicy {
    const policy = POLICIES_BY_ENDPOINT.get(endpoint);
    if (!policy) throw new BadRequestException(`Unknown table: ${endpoint}`);
    return policy;
  }

  private async countRecords(policy: TablePolicy): Promise<number> {
    if (policy.custom === 'menuDish') {
      const rows = await this.getMenuDishRows();
      return rows.length;
    }

    try {
      const prismaModel = (
        this.prisma as unknown as Record<
          string,
          { count: () => Promise<number> }
        >
      )[policy.modelName];
      return prismaModel?.count ? await prismaModel.count() : 0;
    } catch {
      return 0;
    }
  }

  private normalizePagination(input: {
    page?: string;
    limit?: string;
    skip?: string;
    take?: string;
  }): PaginationOptions {
    const take = this.parseOptionalPositiveInteger(input.take);
    const skip = this.parseOptionalNonNegativeInteger(input.skip);
    const limit = Math.min(
      this.parseOptionalPositiveInteger(input.limit) ?? take ?? 20,
      MAX_PAGE_SIZE,
    );
    const pageFromSkip =
      skip === undefined ? undefined : Math.floor(skip / limit) + 1;
    const page =
      this.parseOptionalPositiveInteger(input.page) ?? pageFromSkip ?? 1;

    return { page, limit };
  }

  private buildOrderBy(
    policy: TablePolicy,
    orderBy?: string,
    order?: string,
  ): Record<string, 'asc' | 'desc'> {
    const allowedColumns = new Set(
      policy.schema.columns.map((column) => column.name),
    );
    if (orderBy && allowedColumns.has(orderBy)) {
      return { [orderBy]: order === 'desc' ? 'desc' : 'asc' };
    }
    return policy.defaultOrderBy ?? {};
  }

  private buildSearchWhere(
    policy: TablePolicy,
    search: string,
  ): Record<string, unknown> {
    const searchValue = search.trim();
    if (!searchValue || policy.searchableFields.length === 0) return {};

    return {
      OR: policy.searchableFields.map((field) => ({
        [field]: { contains: searchValue, mode: 'insensitive' },
      })),
    };
  }

  private assertCanWrite(
    policy: TablePolicy,
    action: 'create' | 'update' | 'delete',
  ): void {
    const writePermissions = {
      create: policy.schema.canCreate,
      update: policy.schema.canUpdate,
      delete: policy.schema.canDelete,
    };
    const allowed = writePermissions[action];

    if (!allowed) {
      throw new ForbiddenException(
        `${policy.schema.name} is read-only in DevBoard CRUD`,
      );
    }
  }

  private processData(
    policy: TablePolicy,
    data: Record<string, unknown>,
    action: 'create' | 'update',
  ): Record<string, unknown> {
    const writable = new Set(policy.writableFields);
    const columns = new Map(
      policy.schema.columns.map((column) => [column.name, column]),
    );
    const processed: Record<string, unknown> = {};

    for (const [field, rawValue] of Object.entries(data)) {
      if (!writable.has(field)) continue;

      const column = columns.get(field);
      if (!column) continue;

      const value = this.coerceFieldValue(column, rawValue);
      if (value === undefined) continue;

      processed[field] = this.validateUrlValue(field, value);
    }

    if (Object.keys(processed).length === 0) {
      throw new BadRequestException(
        `No writable fields provided for ${action}`,
      );
    }

    return processed;
  }

  private coerceFieldValue(column: SchemaColumn, rawValue: unknown): unknown {
    if (rawValue === undefined) return undefined;
    if (rawValue === '' || rawValue === null)
      return column.isRequired ? undefined : null;

    switch (column.type) {
      case 'integer':
        return this.parseRequiredInteger(rawValue, column.name);
      case 'decimal':
        return this.parseRequiredDecimal(rawValue, column.name);
      case 'boolean':
        return this.parseRequiredBoolean(rawValue, column.name);
      case 'date':
      case 'datetime':
        return this.parseRequiredDate(rawValue, column.name);
      default:
        return this.stringifyFieldValue(rawValue).trim();
    }
  }

  private validateUrlValue(field: string, value: unknown): unknown {
    if (value === null || value === undefined || !this.isUrlField(field))
      return value;

    const urlValue = this.stringifyFieldValue(value).trim();
    if (!urlValue) return value;
    if (urlValue.startsWith('/') && !urlValue.startsWith('//')) return urlValue;

    let parsed: URL;
    try {
      parsed = new URL(urlValue);
    } catch {
      throw new BadRequestException(`${field} must be a valid URL`);
    }

    const isLocalHttp =
      parsed.protocol === 'http:' &&
      ['localhost', '127.0.0.1', '::1'].includes(parsed.hostname) &&
      process.env.NODE_ENV !== 'production';

    if (parsed.protocol !== 'https:' && !isLocalHttp) {
      throw new BadRequestException(`${field} must use https://`);
    }

    return urlValue;
  }

  private stringifyFieldValue(value: unknown): string {
    if (typeof value === 'string') return value;
    if (
      typeof value === 'number' ||
      typeof value === 'boolean' ||
      typeof value === 'bigint'
    ) {
      return String(value);
    }
    if (value instanceof Date) return value.toISOString();
    return JSON.stringify(value);
  }

  private isUrlField(field: string): boolean {
    const normalized = field.toLowerCase();
    return (
      normalized.endsWith('_url') ||
      normalized.includes('image') ||
      normalized.includes('photo') ||
      normalized.includes('logo') ||
      normalized.includes('icon') ||
      normalized.includes('link')
    );
  }

  private parseUniqueWhere(
    rawId: string,
    policy: TablePolicy,
  ): Record<string, unknown> {
    if (policy.primaryKey.length === 1) {
      const primaryField = policy.primaryKey[0];
      const primaryColumn = policy.schema.columns.find(
        (column) => column.name === primaryField,
      );
      if (!primaryColumn) throw new BadRequestException('Invalid primary key');
      return { [primaryField]: this.coerceFieldValue(primaryColumn, rawId) };
    }

    const compositeValue = this.parseCompositeKey(rawId, policy.primaryKey);
    return { [policy.primaryKey.join('_')]: compositeValue };
  }

  private parseCompositeKey(
    rawId: string,
    primaryKey: string[],
  ): Record<string, number> {
    const decoded = decodeURIComponent(rawId);
    let parsed: unknown;

    try {
      parsed = JSON.parse(decoded);
    } catch {
      parsed = Object.fromEntries(
        decoded.split(/[;,]/).map((part) => {
          const [key, value] = part.split('=');
          return [key, value];
        }),
      );
    }

    if (!parsed || typeof parsed !== 'object') {
      throw new BadRequestException('Invalid composite key');
    }

    const source = parsed as Record<string, unknown>;
    const result: Record<string, number> = {};
    for (const key of primaryKey) {
      result[key] = this.parseRequiredInteger(source[key], key);
    }

    return result;
  }

  private async findMenuDishes(
    pagination: PaginationOptions,
    search?: string,
  ): Promise<PaginatedResult<Record<string, unknown>>> {
    const rows = await this.getMenuDishRows();
    const searchValue = search?.trim().toLowerCase();
    const filteredRows = searchValue
      ? rows.filter(
          (row) =>
            row.menu_title.toLowerCase().includes(searchValue) ||
            row.dish_title.toLowerCase().includes(searchValue),
        )
      : rows;
    const skip = (pagination.page - 1) * pagination.limit;
    const data = filteredRows.slice(
      skip,
      skip + pagination.limit,
    ) as unknown as Record<string, unknown>[];

    return {
      data,
      meta: {
        total: filteredRows.length,
        page: pagination.page,
        limit: pagination.limit,
        totalPages: Math.ceil(filteredRows.length / pagination.limit),
      },
    };
  }

  private async findMenuDish(
    key: Record<string, number>,
  ): Promise<MenuDishRow | null> {
    const rows = await this.getMenuDishRows();
    return (
      rows.find(
        (row) => row.menu_id === key.menu_id && row.dish_id === key.dish_id,
      ) ?? null
    );
  }

  private async createMenuDish(
    data: Record<string, unknown>,
  ): Promise<MenuDishRow> {
    const menuId = this.parseRequiredInteger(data.menu_id, 'menu_id');
    const dishId = this.parseRequiredInteger(data.dish_id, 'dish_id');
    const prisma = this.prisma as unknown as MenuDishPrisma;
    const [menu, dish] = await Promise.all([
      prisma.menu.findUnique({
        where: { id: menuId },
        select: { id: true, title: true },
      }),
      prisma.dish.findUnique({
        where: { id: dishId },
        select: { id: true, title: true },
      }),
    ]);

    if (!menu) throw new BadRequestException(`Menu ${menuId} does not exist`);
    if (!dish) throw new BadRequestException(`Dish ${dishId} does not exist`);

    await prisma.menu.update({
      where: { id: menuId },
      data: { Dish: { connect: { id: dishId } } },
    });

    return {
      menu_id: menu.id,
      dish_id: dish.id,
      menu_title: menu.title,
      dish_title: dish.title,
    };
  }

  private async deleteMenuDish(key: Record<string, number>) {
    const prisma = this.prisma as unknown as MenuDishPrisma;
    await prisma.menu.update({
      where: { id: key.menu_id },
      data: { Dish: { disconnect: { id: key.dish_id } } },
    });
    return { message: 'Dish detached from menu successfully' };
  }

  private async getMenuDishRows(): Promise<MenuDishRow[]> {
    const prisma = this.prisma as unknown as MenuDishPrisma;
    const menus = await prisma.menu.findMany({
      select: {
        id: true,
        title: true,
        Dish: { select: { id: true, title: true } },
      },
      orderBy: { id: 'asc' },
    });

    return menus.flatMap((menu) =>
      menu.Dish.map((dish) => ({
        menu_id: menu.id,
        dish_id: dish.id,
        menu_title: menu.title,
        dish_title: dish.title,
      })),
    );
  }

  private sanitizePaginated(
    policy: TablePolicy,
    result: PaginatedResult<Record<string, unknown>>,
  ): PaginatedResult<Record<string, unknown>> {
    return {
      ...result,
      data: result.data.map(
        (record) => this.sanitizeRecord(policy, record) ?? {},
      ),
    };
  }

  private sanitizeRecord<T extends Record<string, unknown> | null>(
    policy: TablePolicy,
    record: T,
  ): T {
    if (!record) return record;
    const sensitiveFields = new Set(policy.sensitiveFields ?? []);
    const allowedFields = new Set(
      policy.schema.columns.map((column) => column.name),
    );
    const sanitized: Record<string, unknown> = {};

    for (const [field, value] of Object.entries(record)) {
      if (sensitiveFields.has(field) || !allowedFields.has(field)) continue;
      sanitized[field] = value;
    }

    return sanitized as T;
  }

  private parseOptionalPositiveInteger(value?: string): number | undefined {
    if (!value) return undefined;
    const parsed = Number(value);
    if (!Number.isInteger(parsed) || parsed < 1) return undefined;
    return parsed;
  }

  private parseOptionalNonNegativeInteger(value?: string): number | undefined {
    if (!value) return undefined;
    const parsed = Number(value);
    if (!Number.isInteger(parsed) || parsed < 0) return undefined;
    return parsed;
  }

  private parseRequiredInteger(value: unknown, field: string): number {
    const parsed = typeof value === 'number' ? value : Number(value);
    if (!Number.isInteger(parsed)) {
      throw new BadRequestException(`${field} must be an integer`);
    }
    return parsed;
  }

  private parseRequiredDecimal(value: unknown, field: string): number | string {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (
      typeof value === 'string' &&
      value.trim() !== '' &&
      !Number.isNaN(Number(value))
    ) {
      return value.trim();
    }
    throw new BadRequestException(`${field} must be a decimal number`);
  }

  private parseRequiredBoolean(value: unknown, field: string): boolean {
    if (typeof value === 'boolean') return value;
    if (value === 'true') return true;
    if (value === 'false') return false;
    throw new BadRequestException(`${field} must be a boolean`);
  }

  private parseRequiredDate(value: unknown, field: string): Date {
    const parsed = value instanceof Date ? value : new Date(String(value));
    if (Number.isNaN(parsed.getTime())) {
      throw new BadRequestException(`${field} must be a valid date`);
    }
    return parsed;
  }
}
