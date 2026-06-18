/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rest.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { routes } from '../core/routes.js';
import type { HttpClient, RequestOptions } from '../core/http.js';
import type {
  ChangesCursor,
  ChangesPage,
  ChangesSinceOptions,
  FilterPrimitive,
  RestFilterOperator,
  RestMutationOptions,
  RestOrderOptions,
  RestQueryBuilder as RestQueryBuilderApi,
  RestQueryOptions,
  RestRequestOptions,
  RestResourceBuilder as RestResourceBuilderApi,
} from '../types.js';

type FilterValue = string | number | boolean | null;

export class RestClient {
  constructor(private readonly http: HttpClient) {}

  async root(options: RestRequestOptions = {}): Promise<unknown> {
    return this.http.request(routes.rest.root, requestOptions(options));
  }

  from<Row = Record<string, unknown>>(resource: string): RestResourceBuilder<Row> {
    return new RestResourceBuilder<Row>(this.http, resource);
  }

  async rpc<TResult = unknown, TPayload = Record<string, unknown>>(
    name: string,
    payload?: TPayload,
    options: RestRequestOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(routes.rest.rpc(name), {
      ...requestOptions(options),
      method: 'POST',
      body: payload ?? {},
    });
  }
}

export class RestResourceBuilder<Row = Record<string, unknown>> implements RestResourceBuilderApi<Row> {
  constructor(
    private readonly http: HttpClient,
    private readonly resource: string,
  ) {}

  select<TResult = Row[]>(options: RestQueryOptions<Row> = {}): Promise<TResult> {
    return this.http.request<TResult>(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
      ...requestOptions(options),
      method: 'GET',
    });
  }

  async exists(options: RestQueryOptions<Row> = {}): Promise<boolean> {
    const rows = await this.select<Row[]>({ ...options, columns: 'id', limit: 1 });
    return Array.isArray(rows) && rows.length > 0;
  }

  insert<TResult = Row>(
    values: Partial<Row> | Array<Partial<Row>>,
    options: RestMutationOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(routes.rest.resource(this.resource), {
      ...requestOptions(options),
      method: 'POST',
      headers: mutationHeaders(options),
      body: values,
    });
  }

  update<TResult = Row[]>(
    values: Partial<Row>,
    options: RestQueryOptions<Row> & RestMutationOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
      ...requestOptions(options),
      method: 'PATCH',
      headers: mutationHeaders(options),
      body: values,
    });
  }

  delete<TResult = Row[]>(options: RestQueryOptions<Row> & RestMutationOptions = {}): Promise<TResult> {
    return this.http.request<TResult>(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
      ...requestOptions(options),
      method: 'DELETE',
      headers: mutationHeaders(options),
    });
  }

  query(options: RestRequestOptions = {}): RestQueryBuilder<Row> {
    return new RestQueryBuilder<Row>(this.http, this.resource, options);
  }

  /**
   * Keyset-paginated "changes since a cursor" — an offline-sync foundation.
   *
   * Built entirely from existing PostgREST primitives (no server change):
   *   GET /rest/v1/<resource>?<cursorColumn>=gt.<cursor>&order=<cursorColumn>.asc&limit=<n>
   *
   * Returns one ascending page plus `nextCursor` (the cursor column value of the
   * last row). Drive a full sync by looping while `hasMore`, feeding `nextCursor`
   * back in. The cursor column must be monotonically increasing.
   */
  async changesSince(
    cursor: ChangesCursor = null,
    options: ChangesSinceOptions<Row> = {},
  ): Promise<ChangesPage<Row>> {
    const cursorColumn = String(options.cursorColumn ?? 'updated_at');
    const limit = options.limit ?? 100;
    const comparator = options.comparator ?? 'gt';

    const params = new URLSearchParams();
    if (options.columns) params.set('select', options.columns);
    params.set('order', `${cursorColumn}.asc`);
    params.set('limit', String(limit));
    if (cursor !== null && cursor !== undefined) {
      params.append(cursorColumn, `${comparator}.${encodeFilterValue(cursor)}`);
    }

    const rows = await this.http.request<Row[]>(
      `${routes.rest.resource(this.resource)}?${params.toString()}`,
      { ...requestOptions(options), method: 'GET' },
    );
    const list = Array.isArray(rows) ? rows : [];
    const hasMore = list.length >= limit;
    const last = list[list.length - 1] as Record<string, unknown> | undefined;
    const nextCursor = last && cursorColumn in last
      ? (last[cursorColumn] as ChangesCursor)
      : cursor ?? null;

    return { rows: list, nextCursor: hasMore ? nextCursor : null, hasMore };
  }
}

interface BuilderState {
  columns?: string;
  limit?: number;
  offset?: number;
  order: string[];
  /** Raw `key=value` PostgREST query params (filters, or-groups). */
  params: Array<[string, string]>;
  /** PostgREST single-object mode (`Accept: application/vnd.pgrst.object+json`). */
  single: boolean;
  /** `maybeSingle()` — single mode that tolerates "no rows" (returns null). */
  maybe: boolean;
}

/**
 * Supabase-js-style fluent REST builder. Every filter/order/range method
 * mutates an internal {@link BuilderState} and returns `this`; the chain is a
 * thenable, so `await client.from('t').query().eq(...).order(...)` issues the
 * GET only when awaited. The resulting URL is byte-identical to what the
 * options-object `RestResourceBuilder.select()` would build for the same
 * filters — same PostgREST request shape, just chained.
 */
export class RestQueryBuilder<Row = Record<string, unknown>, TResult = Row[]>
  implements RestQueryBuilderApi<Row, TResult>
{
  private readonly state: BuilderState = { order: [], params: [], single: false, maybe: false };

  constructor(
    private readonly http: HttpClient,
    private readonly resource: string,
    private readonly options: RestRequestOptions,
  ) {}

  select(columns?: string): this {
    if (columns) this.state.columns = columns;
    return this;
  }

  eq(column: keyof Row | string, value: FilterPrimitive): this { return this.filter(column, 'eq', value); }
  neq(column: keyof Row | string, value: FilterPrimitive): this { return this.filter(column, 'neq', value); }
  gt(column: keyof Row | string, value: FilterPrimitive): this { return this.filter(column, 'gt', value); }
  gte(column: keyof Row | string, value: FilterPrimitive): this { return this.filter(column, 'gte', value); }
  lt(column: keyof Row | string, value: FilterPrimitive): this { return this.filter(column, 'lt', value); }
  lte(column: keyof Row | string, value: FilterPrimitive): this { return this.filter(column, 'lte', value); }
  like(column: keyof Row | string, pattern: string): this { return this.filter(column, 'like', pattern); }
  ilike(column: keyof Row | string, pattern: string): this { return this.filter(column, 'ilike', pattern); }
  is(column: keyof Row | string, value: FilterPrimitive): this { return this.filter(column, 'is', value); }

  in(column: keyof Row | string, values: ReadonlyArray<FilterPrimitive>): this {
    const list = values.map((v) => encodeInValue(v)).join(',');
    this.state.params.push([String(column), `in.(${list})`]);
    return this;
  }

  or(filter: string): this {
    this.state.params.push(['or', `(${filter})`]);
    return this;
  }

  order(column: keyof Row | string, options: RestOrderOptions = {}): this {
    const dir = options.ascending === false ? 'desc' : 'asc';
    const nulls = options.nullsFirst === undefined
      ? ''
      : options.nullsFirst ? '.nullsfirst' : '.nullslast';
    this.state.order.push(`${String(column)}.${dir}${nulls}`);
    return this;
  }

  limit(count: number): this {
    this.state.limit = count;
    return this;
  }

  range(from: number, to: number): this {
    this.state.offset = from;
    this.state.limit = to - from + 1;
    return this;
  }

  single(): RestQueryBuilder<Row, Row> {
    this.state.single = true;
    this.state.maybe = false;
    return this as unknown as RestQueryBuilder<Row, Row>;
  }

  maybeSingle(): RestQueryBuilder<Row, Row | null> {
    this.state.single = true;
    this.state.maybe = true;
    return this as unknown as RestQueryBuilder<Row, Row | null>;
  }

  then<TFulfilled = TResult, TRejected = never>(
    onFulfilled?: ((value: TResult) => TFulfilled | PromiseLike<TFulfilled>) | null,
    onRejected?: ((reason: unknown) => TRejected | PromiseLike<TRejected>) | null,
  ): Promise<TFulfilled | TRejected> {
    return this.run().then(onFulfilled, onRejected);
  }

  private filter(column: keyof Row | string, operator: RestFilterOperator, value: FilterValue): this {
    this.state.params.push([String(column), `${operator}.${encodeFilterValue(value)}`]);
    return this;
  }

  private async run(): Promise<TResult> {
    const result = await this.http.request<unknown>(`${routes.rest.resource(this.resource)}${this.buildQuery()}`, {
      ...requestOptions(this.options),
      method: 'GET',
      headers: this.buildHeaders(),
    });
    return this.coerce(result);
  }

  private coerce(result: unknown): TResult {
    if (!this.state.single) return result as TResult;
    if (this.state.maybe) {
      if (result === undefined || result === null) return null as TResult;
      return (Array.isArray(result) ? (result[0] ?? null) : result) as TResult;
    }
    return (Array.isArray(result) ? result[0] : result) as TResult;
  }

  private buildHeaders(): HeadersInit | undefined {
    const headers = new Headers(this.options.headers);
    if (this.state.single) {
      headers.set('Accept', 'application/vnd.pgrst.object+json');
    }
    return this.state.single || this.options.headers ? headers : undefined;
  }

  private buildQuery(): string {
    const params = new URLSearchParams();
    if (this.state.columns) params.set('select', this.state.columns);
    if (this.state.limit !== undefined) params.set('limit', String(this.state.limit));
    if (this.state.offset !== undefined) params.set('offset', String(this.state.offset));
    if (this.state.order.length) params.set('order', this.state.order.join(','));
    for (const [key, value] of this.state.params) params.append(key, value);
    const value = params.toString();
    return value ? `?${value}` : '';
  }
}

function requestOptions(options: RestRequestOptions): RequestOptions {
  return {
    apiKey: options.apiKey,
    bearerToken: options.bearerToken,
    headers: options.headers,
    timeoutMs: options.timeoutMs,
    signal: options.signal,
  };
}

function mutationHeaders(options: RestMutationOptions): HeadersInit {
  const headers = new Headers(options.headers);
  headers.set('Prefer', options.returning === 'minimal' ? 'return=minimal' : 'return=representation');
  return headers;
}

function queryString<Row>(options: RestQueryOptions<Row>): string {
  const params = new URLSearchParams();
  if (options.columns) params.set('select', options.columns);
  if (options.limit !== undefined) params.set('limit', String(options.limit));
  if (options.offset !== undefined) params.set('offset', String(options.offset));
  if (options.order) params.set('order', options.order);

  for (const filter of Object.values(normalizeFilters(options.filters))) {
    params.append(String(filter.column), `${filter.operator}.${encodeFilterValue(filter.value)}`);
  }

  const value = params.toString();
  return value ? `?${value}` : '';
}

function normalizeFilters<Row>(filters: RestQueryOptions<Row>['filters'] = {}): Array<{ column: string; operator: RestFilterOperator; value: FilterValue }> {
  if (Array.isArray(filters)) {
    return filters.map((filter) => ({ ...filter, column: String(filter.column) }));
  }
  return Object.entries(filters).map(([column, value]) => ({ column, operator: 'eq', value: value as FilterValue }));
}

function encodeFilterValue(value: FilterValue): string {
  if (value === null) return 'null';
  return String(value);
}

/** Encode one member of a PostgREST `in.(...)` list (quote strings w/ commas). */
function encodeInValue(value: FilterPrimitive): string {
  if (value === null) return 'null';
  if (typeof value === 'string' && /[,"()]/.test(value)) {
    return `"${value.replace(/"/g, '\\"')}"`;
  }
  return String(value);
}
