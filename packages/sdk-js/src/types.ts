import type { AuthSession, User } from './core/session.js';

export interface SignInWithPasswordInput {
  email: string;
  password: string;
}

export interface QueryRunInput<TPayload = Record<string, unknown>> {
  databaseId?: string;
  action: string;
  resource: string;
  payload?: TPayload;
}

export interface QueryRunResponse<TResult = unknown> {
  data: TResult;
  count?: number;
  meta?: Record<string, unknown>;
}

export interface ResourceQueryBuilder<Row = Record<string, unknown>> {
  select<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
  insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>): Promise<TResult>;
  update<TResult = Row[]>(values: Partial<Row>, filter?: Record<string, unknown>): Promise<TResult>;
  delete<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
  run<TResult = unknown, TPayload = Record<string, unknown>>(
    action: string,
    payload?: TPayload,
  ): Promise<TResult>;
}

export interface PresignInput {
  bucket: string;
  key: string;
  method?: 'GET' | 'PUT';
  contentType?: string;
}

export interface AnalyticsTrackInput {
  eventType: string;
  data?: Record<string, unknown>;
}

export type { AuthSession, User };
