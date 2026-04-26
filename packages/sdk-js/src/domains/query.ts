import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import type { QueryRunInput, QueryRunResponse, ResourceQueryBuilder as ResourceQueryBuilderApi } from '../types.js';

interface BackendQueryInput<TPayload> {
  database_id: string;
  action: string;
  resource: string;
  payload?: TPayload;
}

export class QueryClient {
  constructor(
    private readonly http: HttpClient,
    private readonly defaultDatabaseId: string,
  ) {}

  async run<TResult = unknown, TPayload = Record<string, unknown>>(
    input: QueryRunInput<TPayload>,
  ): Promise<TResult> {
    const response = await this.http.request<QueryRunResponse<TResult> | TResult>(routes.query.execute, {
      method: 'POST',
      body: toBackendQuery(input, this.defaultDatabaseId),
    });

    return unwrapData(response);
  }

  from<Row = Record<string, unknown>>(resource: string, databaseId?: string): ResourceQueryBuilder<Row> {
    return new ResourceQueryBuilder<Row>(this, resource, databaseId);
  }
}

export class ResourceQueryBuilder<Row = Record<string, unknown>> implements ResourceQueryBuilderApi<Row> {
  constructor(
    private readonly query: QueryClient,
    private readonly resource: string,
    private readonly databaseId?: string,
  ) {}

  select<TResult = Row[]>(filter: Record<string, unknown> = {}): Promise<TResult> {
    return this.run<TResult>('select', { filter });
  }

  insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>): Promise<TResult> {
    return this.run<TResult>('insert', { values });
  }

  update<TResult = Row[]>(values: Partial<Row>, filter: Record<string, unknown> = {}): Promise<TResult> {
    return this.run<TResult>('update', { values, filter });
  }

  delete<TResult = Row[]>(filter: Record<string, unknown> = {}): Promise<TResult> {
    return this.run<TResult>('delete', { filter });
  }

  run<TResult = unknown, TPayload = Record<string, unknown>>(
    action: string,
    payload?: TPayload,
  ): Promise<TResult> {
    return this.query.run<TResult, TPayload>({
      databaseId: this.databaseId,
      action,
      resource: this.resource,
      payload,
    });
  }
}

function toBackendQuery<TPayload>(
  input: QueryRunInput<TPayload>,
  defaultDatabaseId: string,
): BackendQueryInput<TPayload> {
  return {
    database_id: input.databaseId ?? defaultDatabaseId,
    action: input.action,
    resource: input.resource,
    payload: input.payload,
  };
}

function unwrapData<TResult>(response: QueryRunResponse<TResult> | TResult): TResult {
  if (response && typeof response === 'object' && 'data' in response) {
    return (response as QueryRunResponse<TResult>).data;
  }

  return response as TResult;
}
