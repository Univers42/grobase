/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   types.ts                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

export type { AuthSession, User } from './core/session.js';

export interface SignInWithPasswordInput {
  email: string;
  password: string;
}

export interface SignUpInput {
  email: string;
  password: string;
  data?: Record<string, unknown>;
}

export interface RecoverInput {
  email: string;
}

export interface VerifyInput {
  type: 'signup' | 'recovery' | 'magiclink' | 'email_change';
  token?: string;
  token_hash?: string;
}

export interface UpdateUserInput {
  email?: string;
  password?: string;
  data?: Record<string, unknown>;
}

/** External OAuth provider gotrue can redirect to (`/auth/v1/authorize`). */
export type OAuthProvider =
  | 'google' | 'github' | 'gitlab' | 'bitbucket' | 'azure' | 'apple'
  | 'discord' | 'facebook' | 'twitter' | 'slack' | 'spotify'
  | 'fortytwo' | 'keycloak' | 'workos' | (string & {});

/** Input for `auth.signInWithOAuth()` — builds the gotrue authorize URL. */
export interface SignInWithOAuthInput {
  provider: OAuthProvider;
  /** Where gotrue sends the browser back after the provider callback. */
  redirectTo?: string;
  /** Space- or comma-separated provider scopes (e.g. `'repo read:user'`). */
  scopes?: string;
  /** Extra query params appended to the authorize URL (provider-specific). */
  queryParams?: Record<string, string>;
}

/** Result of `auth.signInWithOAuth()` — the URL to open in the browser. */
export interface SignInWithOAuthResult {
  provider: OAuthProvider;
  url: string;
}

/** MFA factor types gotrue supports today (`/auth/v1/factors`). */
export type MfaFactorType = 'totp' | 'phone';

/** Body for `auth.mfa.enroll()`. */
export interface MfaEnrollInput {
  factorType?: MfaFactorType;
  /** Human-friendly factor name. */
  friendlyName?: string;
  /** Issuer label embedded in the TOTP otpauth URI. */
  issuer?: string;
  /** Phone number — required when `factorType: 'phone'`. */
  phone?: string;
}

/** Response of an MFA enrollment (TOTP carries the QR/secret). */
export interface MfaEnrollResult {
  id: string;
  type: MfaFactorType;
  friendly_name?: string;
  totp?: {
    qr_code: string;
    secret: string;
    uri: string;
  };
  [key: string]: unknown;
}

/** Body for `auth.mfa.challenge()`. */
export interface MfaChallengeInput {
  factorId: string;
}

/** Response of an MFA challenge — `id` is passed back to `verify()`. */
export interface MfaChallengeResult {
  id: string;
  expires_at?: number;
  [key: string]: unknown;
}

/** Body for `auth.mfa.verify()` — confirms a challenge with a code. */
export interface MfaVerifyInput {
  factorId: string;
  challengeId: string;
  /** The TOTP / SMS code the user entered. */
  code: string;
}

export interface AdminCreateUserInput extends SignUpInput {
  email_confirm?: boolean;
  user_metadata?: Record<string, unknown>;
}

export interface AdminUpdateUserInput {
  email?: string;
  password?: string;
  email_confirm?: boolean;
  user_metadata?: Record<string, unknown>;
  app_metadata?: Record<string, unknown>;
}

export interface AdminGenerateLinkInput extends SignUpInput {
  type: 'signup' | 'recovery' | 'magiclink' | 'email_change_current' | 'email_change_new';
  redirect_to?: string;
  data?: Record<string, unknown>;
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

export type RestFilterOperator =
  | 'eq' | 'neq' | 'gt' | 'gte' | 'lt' | 'lte' | 'like' | 'ilike' | 'is' | 'in';

/** Options for the fluent builder's `.order()` — PostgREST sort direction. */
export interface RestOrderOptions {
  /** `true` → `.asc`, `false` → `.desc` (PostgREST default is ascending). */
  ascending?: boolean;
  /** `true` → `.nullsfirst`, `false` → `.nullslast`. */
  nullsFirst?: boolean;
}

/**
 * Supabase-shaped chainable REST builder (`.eq/.in/.or/.order/.range/.single`).
 * Each method returns `this`, and the chain is a thenable that resolves to the
 * PostgREST rows — the same wire shape the options-object `select()` produces.
 */
export interface RestQueryBuilder<Row = Record<string, unknown>, TResult = Row[]>
  extends PromiseLike<TResult> {
  select(columns?: string): RestQueryBuilder<Row, TResult>;
  eq(column: keyof Row | string, value: FilterPrimitive): RestQueryBuilder<Row, TResult>;
  neq(column: keyof Row | string, value: FilterPrimitive): RestQueryBuilder<Row, TResult>;
  gt(column: keyof Row | string, value: FilterPrimitive): RestQueryBuilder<Row, TResult>;
  gte(column: keyof Row | string, value: FilterPrimitive): RestQueryBuilder<Row, TResult>;
  lt(column: keyof Row | string, value: FilterPrimitive): RestQueryBuilder<Row, TResult>;
  lte(column: keyof Row | string, value: FilterPrimitive): RestQueryBuilder<Row, TResult>;
  like(column: keyof Row | string, pattern: string): RestQueryBuilder<Row, TResult>;
  ilike(column: keyof Row | string, pattern: string): RestQueryBuilder<Row, TResult>;
  is(column: keyof Row | string, value: FilterPrimitive): RestQueryBuilder<Row, TResult>;
  in(column: keyof Row | string, values: ReadonlyArray<FilterPrimitive>): RestQueryBuilder<Row, TResult>;
  /** Raw PostgREST `or=` group, e.g. `or('age.gt.18,name.eq.Al')`. */
  or(filter: string): RestQueryBuilder<Row, TResult>;
  order(column: keyof Row | string, options?: RestOrderOptions): RestQueryBuilder<Row, TResult>;
  limit(count: number): RestQueryBuilder<Row, TResult>;
  range(from: number, to: number): RestQueryBuilder<Row, TResult>;
  /** Expect exactly one row — resolves to a single `Row` (not an array). */
  single(): RestQueryBuilder<Row, Row>;
  /** Expect at most one row — resolves to `Row | null`. */
  maybeSingle(): RestQueryBuilder<Row, Row | null>;
}

/** Scalar value accepted by a fluent filter clause. */
export type FilterPrimitive = string | number | boolean | null;

export interface RestRequestOptions {
  apiKey?: string;
  bearerToken?: string;
  headers?: HeadersInit;
  /** Per-call timeout override (ms); falls back to the client default. */
  timeoutMs?: number;
  /** External abort signal — composed with the per-call timeout. */
  signal?: AbortSignal;
}

export interface RestQueryOptions<Row = Record<string, unknown>> extends RestRequestOptions {
  columns?: string;
  limit?: number;
  offset?: number;
  order?: string;
  filters?: Partial<Record<keyof Row | string, string | number | boolean | null>> | Array<{
    column: keyof Row | string;
    operator: RestFilterOperator;
    value: string | number | boolean | null;
  }>;
}

export interface RestMutationOptions extends RestRequestOptions {
  returning?: 'representation' | 'minimal';
}

/**
 * Cursor for keyset (offline-sync) pagination. The cursor is the value of the
 * ordering column on the last row returned — pass it back to fetch the next
 * page. `null`/`undefined` starts from the beginning.
 */
export type ChangesCursor = string | number | null;

export interface ChangesSinceOptions<Row = Record<string, unknown>> extends RestRequestOptions {
  /**
   * Column to page on — must be monotonically increasing (e.g. `updated_at`,
   * a serial `id`, or a logical sequence). Defaults to `updated_at`.
   */
  cursorColumn?: keyof Row | string;
  /** Page size. Default 100. */
  limit?: number;
  /** Columns to select (PostgREST `select=`). Default all. */
  columns?: string;
  /**
   * `gt` (strictly after the cursor — default) or `gte` (inclusive). Use `gt`
   * for strictly-increasing keys; `gte` only with a de-dup strategy.
   */
  comparator?: 'gt' | 'gte';
}

/** One page of {@link RestResourceBuilder.changesSince}. */
export interface ChangesPage<Row = Record<string, unknown>> {
  /** Rows in this page, ordered ascending by the cursor column. */
  rows: Row[];
  /** Cursor to pass to the next `changesSince` call, or `null` when drained. */
  nextCursor: ChangesCursor;
  /** True when this page filled `limit` (more rows may remain). */
  hasMore: boolean;
}

export interface RestResourceBuilder<Row = Record<string, unknown>> {
  select<TResult = Row[]>(options?: RestQueryOptions<Row>): Promise<TResult>;
  exists(options?: RestQueryOptions<Row>): Promise<boolean>;
  insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>, options?: RestMutationOptions): Promise<TResult>;
  update<TResult = Row[]>(values: Partial<Row>, options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
  delete<TResult = Row[]>(options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
  /**
   * Open a supabase-js-style fluent, chainable read builder. Back-compat: the
   * options-object `select(options)` above is unchanged; this is the new path.
   *   await client.from('users').query().select('id,name').eq('active', true).single()
   */
  query(options?: RestRequestOptions): RestQueryBuilder<Row>;
  /**
   * Keyset-paginated "changes since a cursor" — an offline-sync foundation.
   * Returns one page of rows strictly after `cursor` (ordered by the cursor
   * column) plus a `nextCursor`. Built entirely from existing PostgREST query
   * primitives (`order` + `gt`/`gte` + `limit`) — no server change.
   */
  changesSince(cursor?: ChangesCursor, options?: ChangesSinceOptions<Row>): Promise<ChangesPage<Row>>;
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

// ── Transactions (POST /query/v1/txn) ────────────────────────────────────────

/** Write operations permitted inside a single-mount atomic batch. */
export type TxnOp = 'insert' | 'update' | 'delete' | 'upsert';

/** One operation in a transactional batch — same fields as a single write. */
export interface TxnOperation {
  op: TxnOp;
  /** Target resource (table/collection) on the mount. */
  resource: string;
  /** Row data for insert / update / upsert. */
  data?: Record<string, unknown>;
  /** WHERE / filter for update / delete. */
  filter?: Record<string, unknown>;
  /** Idempotency key forwarded to the engine. */
  idempotencyKey?: string;
}

/**
 * Request for `client.txn.execute()` — a single-mount atomic batch. Every op
 * runs in one backend transaction on `databaseId` and commits all-or-nothing
 * (rolled back on the first failure). The engine must be transactional
 * (postgresql/mysql); other engines are rejected.
 */
export interface TxnExecuteInput {
  /** Mount id (dbId); all operations run in one transaction on it. */
  databaseId: string;
  /** 1–50 write ops applied atomically (all-or-nothing). */
  operations: TxnOperation[];
}

/** Per-operation outcome inside a committed transaction. */
export interface TxnOpResult {
  op: string;
  resource: string;
  rowCount: number;
}

/** Result of a single-mount atomic batch. */
export interface TxnResult {
  guarantee: 'atomic';
  mount: string;
  results: TxnOpResult[];
}

// ── Schema introspection + DDL (/query/v1/:dbId/schema) ─────────────────────

/**
 * Engine-agnostic normalized column types returned by `schema.describe()`.
 * `objectid` and `unknown` are describe-only — DDL rejects them (see
 * {@link DdlColumnType}).
 */
export type NormalizedType =
  | 'text'
  | 'integer'
  | 'float'
  | 'decimal'
  | 'boolean'
  | 'date'
  | 'datetime'
  | 'json'
  | 'uuid'
  | 'enum'
  | 'array'
  | 'objectid'
  | 'unknown';

/** Normalized types creatable via DDL (`objectid`/`unknown` are describe-only). */
export type DdlColumnType = Exclude<NormalizedType, 'objectid' | 'unknown'>;

/** One column of a described table (snake_case — the exact wire shape). */
export interface ColumnSchema {
  name: string;
  /** Engine-native type, e.g. `character varying(255)` or `int unsigned`. */
  native_type: string;
  normalized_type: NormalizedType;
  nullable: boolean;
  /** Raw engine default expression, or `null` when the column has none. */
  default: string | null;
  /** Allowed values when `normalized_type` is `enum`; `null` otherwise. */
  enum_values: string[] | null;
  /** Foreign-key target, or `null` when the column references nothing. */
  references: { table: string; column: string } | null;
  /** `true` only for Mongo sample-based inference (no `$jsonSchema` validator). */
  inferred: boolean;
}

/** One table/collection of a described database. */
export interface TableSchema {
  name: string;
  primary_key: string[];
  columns: ColumnSchema[];
}

/**
 * Live engine capability descriptor embedded in `schema.describe()` responses.
 * Mirrors the Rust router's `/v1/capabilities` per-engine payload (the same
 * source `introspectEngines()` validates against). Kept loose
 * (`[key: string]: unknown`) so a new Rust flag does not break the SDK.
 */
export interface SchemaEngineCapabilities {
  read: boolean;
  write: boolean;
  upsert: boolean;
  batch?: boolean;
  aggregate?: boolean;
  /** Engine answers `GET /query/v1/:dbId/schema` (describe). */
  introspect?: boolean;
  /** Engine answers `POST /query/v1/:dbId/schema/ddl` — distinct from `ddl`. */
  schema_ddl?: boolean;
  stream: boolean;
  /** Admin migration-batch surface (`/admin/v1/migrate`) — NOT `schema_ddl`. */
  ddl: boolean;
  transactions: boolean;
  [key: string]: unknown;
}

/**
 * Response of `client.schema.describe()` (`GET /query/v1/:dbId/schema`) —
 * the mount's tables with normalized column types plus the engine's live
 * capability descriptor, so one call tells a client both what the data looks
 * like and what it may do with it.
 */
export interface NormalizedSchema {
  dbId: string;
  engine: string;
  /** `null` when the capabilities fetch failed (the schema is still served). */
  capabilities: SchemaEngineCapabilities | null;
  tables: TableSchema[];
}

/**
 * One DDL column definition (snake_case — the exact wire shape).
 * `nullable`/`default`/`enum_values` may be omitted: for `add_column` /
 * `create_table` the server defaults them (nullable, no default); for
 * `alter_column_type` an omitted attribute means "keep what the column has
 * today" (the server merges with the current column).
 */
export interface DdlColumnDef {
  name: string;
  normalized_type: DdlColumnType;
  /** Whether NULLs are allowed (defaults to `true` on create/add). */
  nullable?: boolean;
  /** Raw engine default expression (`0`, `'pending'`, `now()`); `null` clears it. */
  default?: string | null;
  /** Allowed values — required when `normalized_type` is `enum`. */
  enum_values?: string[] | null;
}

/** The supported schema-DDL operations (snake_case, the wire values). */
export type SchemaDdlOp =
  | 'add_column'
  | 'drop_column'
  | 'alter_column_type'
  | 'create_table'
  | 'drop_table';

/** `add_column`: append `column` to `table`. */
export interface SchemaDdlAddColumnInput {
  op: 'add_column';
  table: string;
  column: DdlColumnDef;
}

/** `alter_column_type`: retype `column.name` (omitted attributes are kept). */
export interface SchemaDdlAlterColumnTypeInput {
  op: 'alter_column_type';
  table: string;
  column: DdlColumnDef;
}

/** `create_table`: create `table` with `columns` and a `primary_key`. */
export interface SchemaDdlCreateTableInput {
  op: 'create_table';
  table: string;
  columns: DdlColumnDef[];
  primary_key: string[];
}

/** `drop_column`: destructive — requires `confirm: true` (400 otherwise). */
export interface SchemaDdlDropColumnInput {
  op: 'drop_column';
  table: string;
  column_name: string;
  confirm: true;
}

/** `drop_table`: destructive — requires `confirm: true` (400 otherwise). */
export interface SchemaDdlDropTableInput {
  op: 'drop_table';
  table: string;
  confirm: true;
}

/**
 * Body of `client.schema.ddl()` — ONE operation per request (deliberate:
 * MySQL DDL is auto-commit, a batch would fake atomicity). The union makes
 * each op's required fields — and `confirm: true` on destructive ops — a
 * compile-time requirement, mirroring the server's 400 guard.
 */
export type SchemaDdlInput =
  | SchemaDdlAddColumnInput
  | SchemaDdlAlterColumnTypeInput
  | SchemaDdlCreateTableInput
  | SchemaDdlDropColumnInput
  | SchemaDdlDropTableInput;

/** Result of an applied schema-DDL operation. */
export interface SchemaDdlResult {
  op: SchemaDdlOp;
  table: string;
  /** `'applied'` on success (failures surface as `MiniBaasError` instead). */
  status: string;
  dbId: string;
}

// ── Webhooks (admin-only, /admin/v1/webhooks) ────────────────────────────────

/** Public webhook subscription view (secrets are write-only and never echoed). */
export interface WebhookSubscription {
  id: string;
  tenant_id: string;
  name: string;
  url: string;
  event_types: string[];
  aggregates: string[];
  active: boolean;
  headers: Record<string, string>;
  max_attempts: number;
  timeout_ms: number;
  created_at: string;
  updated_at: string;
}

/** Body for creating a webhook subscription. */
export interface WebhookCreateInput {
  name: string;
  url: string;
  /** HMAC signing secret (write-only — never returned by list/get). */
  secret: string;
  event_types?: string[];
  aggregates?: string[];
  active?: boolean;
  headers?: Record<string, string>;
  max_attempts?: number;
  timeout_ms?: number;
}

/** Body for patching a webhook subscription (all fields optional). */
export interface WebhookUpdateInput {
  url?: string;
  secret?: string;
  event_types?: string[];
  aggregates?: string[];
  active?: boolean;
  headers?: Record<string, string>;
  max_attempts?: number;
  timeout_ms?: number;
}

/** A webhook delivery attempt ledger row. */
export interface WebhookDelivery {
  id: number;
  subscription_id: string;
  tenant_id: string;
  event_id: string;
  aggregate: string;
  event_type: string;
  status: string;
  attempts: number;
  last_error: string | null;
  last_status_code: number | null;
  next_attempt_at: string;
  delivered_at: string | null;
  created_at: string;
}

// ── Tenants (admin-only, /admin/v1/tenants + /admin/v1/provision) ─────────────

/** Public projection of a tenant. */
export interface Tenant {
  id: string;
  uuid: string;
  name: string;
  status: string;
  plan: string;
  owner_user_id: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

/** Body for creating a tenant. */
export interface TenantCreateInput {
  id: string;
  name: string;
  plan?: string;
  owner_user_id?: string;
  metadata?: Record<string, unknown>;
}

/** Body for patching a tenant. */
export interface TenantUpdateInput {
  name?: string;
  plan?: string;
  status?: string;
  metadata?: Record<string, unknown>;
}

/** Redacted API-key view. The full key is only returned once, on issue. */
export interface TenantApiKey {
  id: string;
  tenant_id: string;
  name: string;
  key_prefix: string;
  scopes: string[];
  created_at: string;
  expires_at: string | null;
  last_used_at: string | null;
  revoked_at: string | null;
}

/** Issued key response — carries the cleartext `key` exactly once. */
export interface TenantApiKeyIssued extends TenantApiKey {
  key: string;
}

/** Body for `client.admin.tenants.bootstrap()`. */
export interface TenantBootstrapInput {
  owner_user_id?: string;
  default_role_name?: string;
  default_key_name?: string;
  seed_roles?: boolean;
}

/** Result of a bootstrap (idempotent; api_key omitted on re-bootstrap). */
export interface TenantBootstrapResult {
  tenant: Tenant;
  api_key?: TenantApiKeyIssued;
  roles: string[];
  created: boolean;
  key_reuse?: boolean;
}

/** One data mount to register inside a provision request. */
export interface ProvisionMountSpec {
  engine: string;
  name: string;
  connection_string: string;
  /** "shared_rls" (default), "schema_per_tenant", or "db_per_tenant". */
  isolation?: string;
}

/** Body for `client.admin.provision()` — a declarative tenant stack (G2). */
export interface ProvisionInput {
  tenant: string;
  name?: string;
  owner_user_id?: string;
  default_role_name?: string;
  default_key_name?: string;
  seed_roles?: boolean;
  mounts?: ProvisionMountSpec[];
}

/** Per-mount reconcile outcome. */
export interface ProvisionMountResult {
  engine: string;
  name: string;
  status: string;
  id?: string;
  schema?: string;
  error?: string;
}

/** Result of a declarative provision/reconcile. */
export interface ProvisionResult {
  tenant: Tenant;
  api_key?: TenantApiKeyIssued;
  key_reuse?: boolean;
  created: boolean;
  roles: string[];
  mounts: ProvisionMountResult[];
}

// ── Admin migrate (admin-only, /admin/v1/migrate → Rust data plane) ───────────

/** Signed identity envelope the data-plane migrate endpoint requires. */
export interface MigrateIdentity {
  tenant_id: string;
  /** Optional server-side (Rust `IdentitySource.user_id` is `Option<String>`). */
  user_id?: string;
  /** Closed set — matches the Rust `IdentitySource` enum (snake_case). */
  source: 'signed_envelope' | 'jwt' | 'service_token' | 'test';
  roles: string[];
}

/** Credential reference for the migrate mount descriptor. */
export interface MigrateCredentialRef {
  provider: string;
  reference: string;
  version: string;
}

/** Target mount descriptor for a migration. */
export interface MigrateMount {
  id: string;
  tenant_id: string;
  engine: string;
  name: string;
  credential_ref: MigrateCredentialRef;
  /** Inline DSN (alternative to a registered credential_ref). */
  inline_dsn?: string;
}

/** Body for `client.admin.migrate.run()` — per-tenant schema migration. */
export interface MigrateInput {
  identity: MigrateIdentity;
  mount: MigrateMount;
  /** Idempotency marker name for this migration. */
  name: string;
  /** Ordered DDL/DML statements applied in one migration. */
  statements: string[];
}

// ── Edge functions (/functions/v1) ───────────────────────────────────────────

/** Body for deploying a function's source. */
export interface FunctionDeployInput {
  name: string;
  /** TypeScript/JavaScript source (max 256KB). */
  code: string;
  /** Optional runtime hint (forward-compat; the runtime documents `runtime?`). */
  runtime?: string;
}

/** Result of a deploy. */
export interface FunctionDeployResult {
  name: string;
  bytes: number;
}

/** Metadata for a deployed function. */
export interface FunctionSummary {
  name: string;
  bytes: number;
  updated_at: string;
}

/** Full source of a deployed function. */
export interface FunctionSource {
  name: string;
  code: string;
}

/** Options for invoking a function. */
export interface FunctionInvokeOptions {
  /** HTTP method handed to the function (defaults to POST). */
  method?: string;
  /** Extra request headers forwarded to the function. */
  headers?: HeadersInit;
}

// ── A5: GraphQL (pg_graphql passthrough via PostgREST) ───────────────────────

/** A GraphQL request, POSTed to `/graphql/v1`. */
export interface GraphqlRequest<Variables = Record<string, unknown>> {
  /** The GraphQL document (query or mutation). */
  query: string;
  /** Variables referenced by the document. */
  variables?: Variables;
  /** Operation name when the document defines several. */
  operationName?: string;
}

/**
 * A GraphQL response envelope (per the GraphQL-over-HTTP spec). `data` is
 * present on success; `errors` is present (non-empty) when the operation
 * produced any errors. Both can be present for partial results.
 */
export interface GraphqlResponse<Data = Record<string, unknown>> {
  data?: Data;
  errors?: GraphqlError[];
  extensions?: Record<string, unknown>;
}

/** A single GraphQL error entry. */
export interface GraphqlError {
  message: string;
  path?: (string | number)[];
  locations?: { line: number; column: number }[];
  extensions?: Record<string, unknown>;
}

/** Options for a single GraphQL call. */
export interface GraphqlQueryOptions {
  /** Operation name when the document defines several. */
  operationName?: string;
  /** Extra request headers. */
  headers?: HeadersInit;
}

// ── A2: DB-event -> function triggers (/admin/v1/function-triggers) ───────────

/** Body for creating a DB-event -> function trigger. */
export interface FunctionTriggerCreateInput {
  /** Unique (per tenant) trigger name. */
  name: string;
  /** The deployed function to invoke when an event matches. */
  function_name: string;
  /** Event types to match (e.g. `['created','updated']`). `['*']` = all. */
  event_types?: string[];
  /** Aggregates/tables to match (e.g. `['orders']`). `['*']` = all. */
  aggregates?: string[];
  /** Whether the trigger fires (default true). */
  enabled?: boolean;
  /** Max delivery attempts before DLQ (default 8). */
  max_attempts?: number;
  /** Per-invoke timeout in ms (default 5000). */
  timeout_ms?: number;
}

/** A registered function trigger. */
export interface FunctionTrigger {
  id: string;
  tenant_id: string;
  name: string;
  function_name: string;
  event_types: string[];
  aggregates: string[];
  enabled: boolean;
  max_attempts: number;
  timeout_ms: number;
  created_at: string;
  updated_at: string;
}

// ── A2: scheduled (cron) invocation (/admin/v1/function-schedules) ────────────

/** Body for creating a scheduled function invocation. */
export interface FunctionScheduleCreateInput {
  /** Unique (per tenant) schedule name. */
  name: string;
  /** The deployed function to invoke. */
  function_name: string;
  /**
   * Schedule expression. Supported grammar (zero-dep interval dialect):
   * `@every 30s` | `@every 5m` | `@every 1h` | `@hourly` | `@daily` |
   * `@weekly`, or a bare Go duration like `5m` (a bare integer = seconds).
   */
  schedule_expr: string;
  /** Optional JSON payload handed to the function as the invoke body. */
  payload?: unknown;
  /** Whether the schedule fires (default true). */
  enabled?: boolean;
  /** Per-invoke timeout in ms (default 5000). */
  timeout_ms?: number;
}

/** A registered function schedule. */
export interface FunctionSchedule {
  id: string;
  tenant_id: string;
  name: string;
  function_name: string;
  schedule_expr: string;
  payload: string;
  enabled: boolean;
  timeout_ms: number;
  last_run: string;
  next_run: string;
  last_status: string;
  created_at: string;
  updated_at: string;
}

// ── A2: per-function secrets (/admin/v1/function-secrets) ─────────────────────

/** Body for setting a function secret. */
export interface FunctionSecretSetInput {
  /** Env var name injected into the worker (`[A-Za-z_][A-Za-z0-9_]{0,127}`). */
  key: string;
  /** Secret value (write-only; never returned by list). */
  value: string;
  /** Scope to one function; omit for a tenant-wide secret. */
  function_name?: string;
}

/** Function secret metadata (NEVER includes the plaintext value). */
export interface FunctionSecretMeta {
  key: string;
  function_name: string;
  updated_at: string;
}

// ── B4a: tenant self-service control (/v1/tenants/me*) ────────────────────────
// Callable with EITHER a tenant API key OR a GoTrue user JWT as the bearer; the
// server resolves the calling tenant from the credential. These are the REAL
// server paths (`/v1/tenants/me*`) — distinct from the admin client's
// `/admin/v1/tenants` registry surface.

/** Minimal tenant projection returned by the self-service surface. */
export interface TenantSelf {
  id: string;
  slug: string;
  name: string;
  plan: string;
  status: string;
}

/** What the calling tenant's current plan grants (measured, not invented). */
export interface TenantEntitlements {
  /** Engine ids the plan enables (e.g. `["postgresql"]`). */
  engines: string[];
  /** Capability flags the plan unlocks (e.g. `["realtime","functions"]`). */
  capabilities: string[];
  /** Hard ceilings (rps, mounts, storage, etc.) keyed by limit name. */
  limits: Record<string, number>;
  /** Soft consumption budgets keyed by quota name. */
  quota: Record<string, number>;
  /**
   * The privilege CEILING the tenant may compose within (its paid plan or an
   * operator-minted custom ceiling). The effective entitlement above is the
   * named tier overlaid by the tenant's custom row, CLAMPED to this. Present
   * only when the server runs the builder (`BUILDER_ENABLED`).
   */
  ceiling?: TenantEntitlements;
  /**
   * `true` when a per-tenant custom entitlement is overlaid on the named tier
   * (a self-composed backend or an operator deal); `false`/absent for a plain
   * named tier.
   */
  custom?: boolean;
}

// ── B7/builder: per-tenant dynamic builder (/v1/tenants/me/{mounts,entitlements,builder}) ──
// Self-serve composition WITHIN a ceiling. All caller-scoped (tenant from the
// bearer; no `{id}`). The builder is a control-plane resolver swap — these
// types describe the wire shape only.

/** One data mount the calling tenant owns (its composed backend, per-mount). */
export interface TenantMount {
  id: string;
  tenant_id: string;
  engine: string;
  name: string;
  /** "shared_rls" (default), "schema_per_tenant", or "db_per_tenant". */
  isolation: string;
  status: string;
  created_at: string;
}

/**
 * Body for `account.createMount()` — register a mount on the calling tenant.
 * The engine must be within the tenant's ceiling (else a clean 403). Supply
 * EITHER an inline `connection_string` OR a stored `credential_ref`.
 */
export interface TenantMountCreateInput {
  engine: string;
  name: string;
  /** "shared_rls" (default), "schema_per_tenant", or "db_per_tenant". */
  isolation?: string;
  /** Inline DSN for the mount (alternative to `credential_ref`). */
  connection_string?: string;
  /** Reference to a stored credential (alternative to `connection_string`). */
  credential_ref?: string;
}

/**
 * Body for `account.patchEntitlements()` — narrow/customize the tenant's
 * effective entitlement WITHIN its ceiling. Every field is optional and a
 * partial overlay: capabilities may be turned OFF freely but never ON past the
 * ceiling; engines must be a subset; limits/quota must be ≤ the ceiling. The
 * server validates (clean 403 on violation) and clamps on every resolve.
 */
export interface TenantEntitlementPatch {
  /** Engine ids to allow — must be a subset of the ceiling's engines. */
  engines?: string[];
  /** Capability flags keyed by name; `true` requires the ceiling to allow it. */
  capabilities?: Record<string, boolean>;
  /** Hard limits keyed by name (rps, burst, max_rows, max_mounts, …) ≤ ceiling. */
  limits?: Record<string, number>;
  /** Soft quota budgets keyed by name (e.g. `quota.query.count`) ≤ ceiling. */
  quota?: Record<string, number>;
  /** Addons to enable — must be a subset of the ceiling's addons. */
  addons?: string[];
}

/**
 * Body for `account.previewBuilder()` — a dry-run validation of a proposed
 * entitlement patch + mount set against the ceiling, WITHOUT persisting.
 */
export interface BuilderPreviewInput {
  /** The entitlement overlay to validate (same shape as `patchEntitlements`). */
  entitlements?: TenantEntitlementPatch;
  /** Mounts the tenant intends to register (counted against the mount budget). */
  mounts?: TenantMountCreateInput[];
}

/**
 * Result of `account.previewBuilder()` — what the composition would resolve to.
 * `valid` is false (with `violations`) when the proposal exceeds the ceiling;
 * `clamped` reflects the backstop the server would apply at resolve time.
 */
export interface BuilderPreviewResult {
  /** `true` when the proposal is wholly within the ceiling (no clamping). */
  valid: boolean;
  /** The effective entitlement after clamping to the ceiling. */
  clamped: TenantEntitlements;
  /** Human-readable reasons the proposal exceeds the ceiling (empty when valid). */
  violations: string[];
  /**
   * The opaque per-mount capability mask the data plane would stamp — the same
   * shape the control plane synthesizes from the resolved package.
   */
  effectiveCapabilityOverrides: Record<string, unknown>;
  /** Mount accounting: how many mounts are used vs. the ceiling's max. */
  mountBudget: { used: number; max: number };
}

/** Response of `account.getSelf()` — the tenant plus its entitlements. */
export interface TenantSelfResult {
  tenant: TenantSelf;
  entitlements: TenantEntitlements;
}

/** Response of `account.getUsage()` — metered usage for a billing period. */
export interface TenantUsage {
  /** The period this usage covers (e.g. `"2026-06"`); echoes the query arg. */
  period: string;
  /** Metered counters keyed by metric name (requests, storage_bytes, …). */
  metrics: Record<string, number>;
}

/** Body for `account.createKey()`. */
export interface TenantSelfKeyCreateInput {
  name: string;
  /** Optional scope grant; defaults to the plan's default scopes server-side. */
  scopes?: string[];
}
