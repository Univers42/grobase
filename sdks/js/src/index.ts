/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   index.ts                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:37:19 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { AnalyticsClient } from './domains/analytics.js';
import { AuthClient } from './domains/auth.js';
import { QueryClient, ResourceQueryBuilder } from './domains/query.js';
import { RestClient, RestResourceBuilder, RestQueryBuilder } from './domains/rest.js';
import { SchemaClient } from './domains/schema.js';
import { StorageClient } from './domains/storage.js';
import { TxnClient } from './domains/txn.js';
import { WebhooksClient } from './domains/webhooks.js';
import { AdminClient } from './domains/admin.js';
import { AccountClient } from './domains/account.js';
import { FunctionsClient } from './domains/functions.js';
import { GraphqlClient } from './domains/graphql.js';
import { RealtimeClient } from './domains/realtime-client.js';
import { HttpClient } from './core/http.js';
import { routes } from './core/routes.js';
import { makeEngineClient } from './domains/engine-clients.js';
import { ENGINE_IDS, type EngineId, type EnginesResponse } from './generated/engines.js';
import type { EngineClient } from './domains/engine-clients.js';
import {
  createBrowserStorageAdapter,
  createMemoryStorageAdapter,
  type SessionStorageAdapter,
} from './core/storage.js';
import type { ClientSession, SessionInput } from './core/session.js';
import type { RestRequestOptions } from './types.js';

export type {
  AuthSession,
  ClientSession,
  SessionInput,
  User,
} from './core/session.js';
export type { SessionStorageAdapter } from './core/storage.js';
export {
  MiniBaasError,
  MiniBaasTimeoutError,
  MiniBaasNetworkError,
  MiniBaasClientError,
  MiniBaasBadRequestError,
  MiniBaasUnauthorizedError,
  MiniBaasForbiddenError,
  MiniBaasNotFoundError,
  MiniBaasConflictError,
  MiniBaasRateLimitError,
  MiniBaasServerError,
} from './core/errors.js';
export type {
  AnalyticsTrackInput,
  PresignInput,
  QueryRunInput,
  QueryRunResponse,
  RecoverInput,
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
  SignInWithPasswordInput,
  SignUpInput,
  UpdateUserInput,
  VerifyInput,
  // ── A3: OAuth + MFA auth helpers ─────────────────────────────────────────
  OAuthProvider,
  SignInWithOAuthInput,
  SignInWithOAuthResult,
  MfaFactorType,
  MfaEnrollInput,
  MfaEnrollResult,
  MfaChallengeInput,
  MfaChallengeResult,
  MfaVerifyInput,
  // ── G9: transactions / webhooks / tenants / migrate / functions ──────────
  TxnExecuteInput,
  TxnOp,
  TxnOperation,
  TxnOpResult,
  TxnResult,
  WebhookCreateInput,
  WebhookDelivery,
  WebhookSubscription,
  WebhookUpdateInput,
  Tenant,
  TenantApiKey,
  TenantApiKeyIssued,
  TenantBootstrapInput,
  TenantBootstrapResult,
  TenantCreateInput,
  TenantUpdateInput,
  ProvisionInput,
  ProvisionMountResult,
  ProvisionMountSpec,
  ProvisionResult,
  MigrateCredentialRef,
  MigrateIdentity,
  MigrateInput,
  MigrateMount,
  FunctionDeployInput,
  FunctionDeployResult,
  FunctionInvokeOptions,
  FunctionSource,
  FunctionSummary,
  // ── A2: function triggers / schedules / secrets ──────────────────────────
  FunctionTrigger,
  FunctionTriggerCreateInput,
  FunctionSchedule,
  FunctionScheduleCreateInput,
  FunctionSecretMeta,
  FunctionSecretSetInput,
  // ── B4a: tenant self-service control (/v1/tenants/me*) ────────────────────
  TenantSelf,
  TenantSelfResult,
  TenantEntitlements,
  TenantUsage,
  TenantSelfKeyCreateInput,
  // ── B7/builder: per-tenant dynamic builder (mounts/entitlements/builder) ──
  TenantMount,
  TenantMountCreateInput,
  TenantEntitlementPatch,
  BuilderPreviewInput,
  BuilderPreviewResult,
  // ── M22: schema introspection + DDL ──────────────────────────────────────
  ColumnSchema,
  DdlColumnDef,
  DdlColumnType,
  NormalizedSchema,
  NormalizedType,
  SchemaDdlAddColumnInput,
  SchemaDdlAlterColumnTypeInput,
  SchemaDdlCreateTableInput,
  SchemaDdlDropColumnInput,
  SchemaDdlDropTableInput,
  SchemaDdlInput,
  SchemaDdlOp,
  SchemaDdlResult,
  SchemaEngineCapabilities,
  TableSchema,
  // ── A5: GraphQL ───────────────────────────────────────────────────────────
  GraphqlError,
  GraphqlQueryOptions,
  GraphqlRequest,
  GraphqlResponse,
} from './types.js';

export { SchemaClient } from './domains/schema.js';
export { TxnClient } from './domains/txn.js';
export { WebhooksClient } from './domains/webhooks.js';
export { AdminClient, MigrateClient, TenantsClient } from './domains/admin.js';
export { AccountClient } from './domains/account.js';
export type { AccountClientOptions } from './domains/account.js';
export { FunctionsClient } from './domains/functions.js';
export { StorageClient, StorageBucketClient } from './domains/storage.js';
export { RestClient, RestResourceBuilder, RestQueryBuilder } from './domains/rest.js';
export { AuthClient, AuthAdminClient, AuthMfaClient } from './domains/auth.js';
export type { StorageObject, BucketInfo, UploadResult, UploadOptions, UploadBody } from './domains/storage.js';
export { GraphqlClient } from './domains/graphql.js';
export { RealtimeClient } from './domains/realtime-client.js';
export type {
  PresenceMember,
  RealtimeEvent,
  RealtimeSubscribeOptions,
  RealtimeSubscription,
} from './domains/realtime-client.js';

export interface RetryOptions {
  /** Max total attempts (first try + retries). Default 3. */
  attempts?: number;
  /** Base backoff before the first retry, in ms (grows exponentially). Default 250. */
  delayMs?: number;
  /** Upper bound on any single backoff wait, in ms. Default 10_000. */
  maxDelayMs?: number;
  /** HTTP statuses eligible for retry on idempotent requests. */
  retryOn?: number[];
}

export interface MiniBaasClientOptions {
  url: string;
  anonKey: string;
  fetch?: typeof fetch;
  accessToken?: string;
  refreshToken?: string;
  serviceRoleKey?: string;
  defaultDatabaseId?: string;
  persistSession?: boolean;
  storage?: SessionStorageAdapter;
  storageKey?: string;
  timeoutMs?: number;
  retry?: number | RetryOptions;
}

export class MiniBaasClient {
  readonly auth: AuthClient;
  readonly query: QueryClient;
  readonly rest: RestClient;
  readonly storage: StorageClient;
  readonly analytics: AnalyticsClient;
  /** Single-mount atomic write batches (`POST /query/v1/txn`). */
  readonly txn: TxnClient;
  /** Engine-agnostic schema introspection + DDL (`/query/v1/:dbId/schema`). */
  readonly schema: SchemaClient;
  /** Edge functions (`/functions/v1`). */
  readonly functions: FunctionsClient;
  /**
   * GraphQL passthrough to PostgREST's pg_graphql endpoint (`/graphql/v1`).
   * Requires the `pg_graphql` extension in Postgres (see route docs).
   */
  readonly graphql: GraphqlClient;
  /**
   * Realtime WebSocket client — DB change streams, ephemeral broadcast
   * (client→client), and presence (who's online). See {@link RealtimeClient}.
   */
  readonly realtime: RealtimeClient;
  /**
   * Webhook subscription registry. **Admin-only / server-side**: requires
   * `serviceRoleKey`; the gateway route is internal-only.
   */
  readonly webhooks: WebhooksClient;
  /**
   * Control-plane surface (tenants / provision / migrate). **Admin-only /
   * server-side**: requires `serviceRoleKey`; routes are internal-only.
   */
  readonly admin: AdminClient;
  /**
   * Tenant **self-service** control (`/v1/tenants/me*`) — read your plan,
   * entitlements & usage, manage your own API keys, change plan. Works with the
   * session JWT or a tenant API key (no service-role key needed). See
   * {@link AccountClient}.
   */
  readonly account: AccountClient;

  private readonly http: HttpClient;
  private readonly anonKey: string;

  constructor(options: MiniBaasClientOptions) {
    const sessionStorage = resolveSessionStorage(options);
    const initialSession = sessionStorage.load() ??
      (options.accessToken
        ? { accessToken: options.accessToken, refreshToken: options.refreshToken }
        : undefined);

    this.anonKey = options.anonKey;
    this.http = new HttpClient({
      baseUrl: options.url,
      anonKey: options.anonKey,
      fetch: options.fetch,
      sessionStorage,
      session: initialSession,
      timeoutMs: options.timeoutMs,
      retry: options.retry,
    });

    this.auth = new AuthClient(this.http, options.serviceRoleKey);
    this.query = new QueryClient(this.http, options.defaultDatabaseId ?? 'default');
    this.rest = new RestClient(this.http);
    this.storage = new StorageClient(this.http);
    this.analytics = new AnalyticsClient(this.http);
    this.txn = new TxnClient(this.http);
    this.schema = new SchemaClient(this.http);
    this.functions = new FunctionsClient(this.http, options.serviceRoleKey);
    this.graphql = new GraphqlClient(this.http);
    this.realtime = new RealtimeClient(this.http);
    this.webhooks = new WebhooksClient(this.http, options.serviceRoleKey);
    this.admin = new AdminClient(this.http, options.serviceRoleKey);
    this.account = new AccountClient(this.http);
  }

  from<Row = Record<string, unknown>>(resource: string): RestResourceBuilder<Row> {
    return this.rest.from<Row>(resource);
  }

  fromQuery<Row = Record<string, unknown>>(resource: string, databaseId?: string): ResourceQueryBuilder<Row> {
    return this.query.from<Row>(resource, databaseId);
  }

  /**
   * Open a **capability-typed** client against one engine + database + resource.
   *
   * The returned object's shape is derived from `ENGINE_CAPS[E]` at compile
   * time: `.upsert()` is only present when the engine advertises
   * `upsert: true`, `.subscribe()` only when `stream: true`, etc. Calling
   * a missing method is a TypeScript compile error — not a runtime surprise.
   *
   * @example
   *   const pg = client.engine<'postgresql', User>(dbId, 'users');
   *   await pg.list({ filter: { active: true } });
   *   await pg.transaction(async (tx) => tx.insert({ name: 'Alice' }));
   *   await pg.upsert({ id: 1 });   // ❌ compile error
   */
  engine<E extends EngineId, Row = Record<string, unknown>>(
    engine: E,
    databaseId: string,
    resource: string,
  ): EngineClient<E, Row> {
    return makeEngineClient<E, Row>(this.http, engine, databaseId, resource);
  }

  /**
   * Fetch `/engines` from the running query-router and compare it against
   * the static catalog shipped in `generated/engines.ts`. Resolves to the
   * server-side descriptor; throws if any engine drifts.
   */
  async introspectEngines(): Promise<EnginesResponse> {
    const response = await this.http.request<EnginesResponse>(routes.query.engines, { method: 'GET' });
    const liveIds = new Set(response.engines);
    const staticIds = new Set(ENGINE_IDS);
    for (const id of liveIds) {
      if (!staticIds.has(id)) {
        throw new Error(
          `Engine '${id}' is live on the server but missing from the SDK catalog — regenerate with codegen-engines.mjs.`,
        );
      }
    }
    for (const id of staticIds) {
      if (!liveIds.has(id)) {
        throw new Error(
          `Engine '${id}' is in the SDK catalog but not registered on the server — drift detected.`,
        );
      }
    }
    return response;
  }

  rpc<TResult = unknown, TPayload = Record<string, unknown>>(
    name: string,
    payload?: TPayload,
    options?: RestRequestOptions,
  ): Promise<TResult> {
    return this.rest.rpc<TResult, TPayload>(name, payload, options);
  }

  setSession(session: SessionInput): void {
    this.http.setSession(session);
  }

  getSession(): ClientSession | undefined {
    return this.http.getSession();
  }

  clearSession(): void {
    this.http.clearSession();
  }

  realtimeUrl(channel = 'default'): string {
    const url = this.http.createRealtimeUrl(channel);
    return url.toString();
  }
}

export function createClient(options: MiniBaasClientOptions): MiniBaasClient {
  return new MiniBaasClient(options);
}

// ── M10: engine-aware exports ────────────────────────────────────────────────
export { ENGINE_CAPS, ENGINE_IDS } from './generated/engines.js';
export type {
  EngineCaps,
  EngineDescriptor,
  EngineId,
  EnginesResponse,
  StreamableEngine,
  TransactionalEngine,
  UpsertableEngine,
} from './generated/engines.js';
export type { EngineClient } from './domains/engine-clients.js';

function resolveSessionStorage(options: MiniBaasClientOptions): SessionStorageAdapter {
  if (options.storage) return options.storage;
  if (options.persistSession === false) return createMemoryStorageAdapter();

  return createBrowserStorageAdapter(options.storageKey) ?? createMemoryStorageAdapter();
}
