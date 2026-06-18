/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   functions.ts                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/03 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/03 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { routes } from '../core/routes.js';
import { requireAdminKey } from '../core/admin.js';
import type { HttpClient } from '../core/http.js';
import type {
  FunctionDeployInput,
  FunctionDeployResult,
  FunctionInvokeOptions,
  FunctionScheduleCreateInput,
  FunctionSchedule,
  FunctionSecretMeta,
  FunctionSecretSetInput,
  FunctionSource,
  FunctionSummary,
  FunctionTrigger,
  FunctionTriggerCreateInput,
} from '../types.js';

/**
 * Edge functions (`/functions/v1`).
 *
 * Tenants deploy TS/JS source and invoke it by name; each invocation runs in a
 * sandboxed Deno worker on the runtime. Identity is taken from the gateway's
 * JWT-derived headers, so a regular (non-admin) authenticated client works.
 *
 * Note: the gateway sets `X-User-Id` (from JWT `sub`) but not a tenant header,
 * so the runtime namespaces functions per USER, not per tenant — two users in
 * one tenant get separate function sets. An anon-key-only caller (no JWT) is
 * rejected (401).
 */
export class FunctionsClient {
  constructor(
    private readonly http: HttpClient,
    /**
     * Service-role key for the admin-only A2 surfaces (triggers / schedules /
     * secrets). The deploy/invoke/list/get/delete methods do NOT need it; only
     * the `/admin/v1/function-*` operations do (internal-only at the gateway).
     */
    private readonly serviceRoleKey?: string,
  ) {}

  /** List the calling tenant's deployed functions. */
  list(): Promise<FunctionSummary[]> {
    return this.http.request<FunctionSummary[]>(routes.functions.root, { method: 'GET' });
  }

  /** Deploy (create or overwrite) a function's source. */
  deploy(input: FunctionDeployInput): Promise<FunctionDeployResult> {
    return this.http.request<FunctionDeployResult>(routes.functions.root, {
      method: 'POST',
      body: input,
    });
  }

  /** Fetch a function's source. */
  get(name: string): Promise<FunctionSource> {
    return this.http.request<FunctionSource>(routes.functions.one(name), { method: 'GET' });
  }

  /** Remove a deployed function. */
  delete(name: string): Promise<{ deleted: boolean }> {
    return this.http.request<{ deleted: boolean }>(routes.functions.one(name), { method: 'DELETE' });
  }

  /**
   * Invoke a deployed function by name and return its response body. The
   * runtime relays the function's own status + content type; a non-2xx status
   * surfaces as a {@link MiniBaasError}.
   */
  invoke<TResult = unknown, TPayload = unknown>(
    name: string,
    payload?: TPayload,
    options: FunctionInvokeOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(routes.functions.invoke(name), {
      method: options.method ?? 'POST',
      headers: options.headers,
      body: payload,
    });
  }

  // ── A2: DB-event -> function triggers (admin-only) ──────────────────────────

  /** Register a DB-event -> function trigger. **Requires `serviceRoleKey`.** */
  createTrigger(input: FunctionTriggerCreateInput): Promise<FunctionTrigger> {
    return this.admin<FunctionTrigger>(routes.functions.triggers, 'POST', input);
  }

  /** List the calling tenant's function triggers. **Requires `serviceRoleKey`.** */
  listTriggers(): Promise<FunctionTrigger[]> {
    return this.admin<FunctionTrigger[]>(routes.functions.triggers, 'GET');
  }

  /** Delete a function trigger by id. **Requires `serviceRoleKey`.** */
  deleteTrigger(id: string): Promise<{ deleted: boolean }> {
    return this.admin<{ deleted: boolean }>(routes.functions.trigger(id), 'DELETE');
  }

  // ── A2: scheduled (cron) invocation (admin-only) ────────────────────────────

  /** Register a scheduled function invocation. **Requires `serviceRoleKey`.** */
  createSchedule(input: FunctionScheduleCreateInput): Promise<FunctionSchedule> {
    return this.admin<FunctionSchedule>(routes.functions.schedules, 'POST', input);
  }

  /** List the calling tenant's function schedules. **Requires `serviceRoleKey`.** */
  listSchedules(): Promise<FunctionSchedule[]> {
    return this.admin<FunctionSchedule[]>(routes.functions.schedules, 'GET');
  }

  /** Delete a function schedule by id. **Requires `serviceRoleKey`.** */
  deleteSchedule(id: string): Promise<{ deleted: boolean }> {
    return this.admin<{ deleted: boolean }>(routes.functions.schedule(id), 'DELETE');
  }

  // ── A2: per-function secrets (admin-only) ───────────────────────────────────

  /** Set (upsert) a function secret. **Requires `serviceRoleKey`.** */
  setSecret(input: FunctionSecretSetInput): Promise<FunctionSecretMeta> {
    return this.admin<FunctionSecretMeta>(routes.functions.secrets, 'POST', input);
  }

  /** List secret metadata (never plaintext). **Requires `serviceRoleKey`.** */
  listSecrets(): Promise<FunctionSecretMeta[]> {
    return this.admin<FunctionSecretMeta[]>(routes.functions.secrets, 'GET');
  }

  /**
   * Delete a function secret by key. Pass `functionName` to delete a
   * function-scoped secret; omit it for a tenant-wide one.
   * **Requires `serviceRoleKey`.**
   */
  deleteSecret(key: string, functionName?: string): Promise<{ deleted: boolean }> {
    const path = functionName
      ? `${routes.functions.secret(key)}?function_name=${encodeURIComponent(functionName)}`
      : routes.functions.secret(key);
    return this.admin<{ deleted: boolean }>(path, 'DELETE');
  }

  /** Shared request path for the admin-only A2 surfaces. */
  private admin<TResult>(path: string, method: string, body?: unknown): Promise<TResult> {
    const key = requireAdminKey(this.serviceRoleKey, 'functions');
    return this.http.request<TResult>(path, { method, body, apiKey: key, bearerToken: key });
  }
}
