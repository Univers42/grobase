/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   admin.ts                                           :+:      :+:    :+:   */
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
  MigrateInput,
  ProvisionInput,
  ProvisionResult,
  Tenant,
  TenantBootstrapInput,
  TenantBootstrapResult,
  TenantCreateInput,
  TenantUpdateInput,
} from '../types.js';

/**
 * Privileged control-plane surface (`/admin/v1/*`).
 *
 * **Admin-only / server-side.** Every route here is internal-only at the
 * gateway (ip-restriction + an upstream service token); the client must be
 * constructed with a `serviceRoleKey`. Do NOT expose this to browser clients.
 */
export class AdminClient {
  readonly tenants: TenantsClient;
  readonly migrate: MigrateClient;

  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {
    this.tenants = new TenantsClient(http, serviceRoleKey);
    this.migrate = new MigrateClient(http, serviceRoleKey);
  }

  /**
   * Declarative tenant-stack reconcile (G2): tenant + first key + default ABAC
   * role + a set of data mounts, idempotently, in one call.
   */
  provision(input: ProvisionInput): Promise<ProvisionResult> {
    const key = requireAdminKey(this.serviceRoleKey, 'provision');
    return this.http.request<ProvisionResult>(routes.tenants.provision, {
      method: 'POST',
      body: input,
      apiKey: key,
      bearerToken: key,
    });
  }
}

/** Tenant registry CRUD + bootstrap (`/admin/v1/tenants`). Admin-only. */
export class TenantsClient {
  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {}

  list(): Promise<Tenant[]> {
    return this.request<Tenant[]>(routes.tenants.root, 'GET');
  }

  create(input: TenantCreateInput): Promise<Tenant> {
    return this.request<Tenant>(routes.tenants.root, 'POST', input);
  }

  get(id: string): Promise<Tenant> {
    return this.request<Tenant>(routes.tenants.one(id), 'GET');
  }

  update(id: string, input: TenantUpdateInput): Promise<Tenant> {
    return this.request<Tenant>(routes.tenants.one(id), 'PATCH', input);
  }

  delete(id: string): Promise<{ deleted: boolean }> {
    return this.request<{ deleted: boolean }>(routes.tenants.one(id), 'DELETE');
  }

  /**
   * Wire up everything a new tenant needs in one call (default ABAC role +
   * first API key + optional default mount). Idempotent on re-bootstrap.
   */
  bootstrap(id: string, input: TenantBootstrapInput = {}): Promise<TenantBootstrapResult> {
    return this.request<TenantBootstrapResult>(routes.tenants.bootstrap(id), 'POST', input);
  }

  private request<TResult>(path: string, method: string, body?: unknown): Promise<TResult> {
    const key = requireAdminKey(this.serviceRoleKey, 'tenants');
    return this.http.request<TResult>(path, { method, body, apiKey: key, bearerToken: key });
  }
}

/**
 * Per-tenant schema migrations (`/admin/v1/migrate` → Rust data plane).
 * Admin-only. The request carries a signed identity envelope, the target mount
 * descriptor and ordered statements; the server applies them under an
 * idempotency marker.
 */
export class MigrateClient {
  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {}

  run<TResult = unknown>(input: MigrateInput): Promise<TResult> {
    const key = requireAdminKey(this.serviceRoleKey, 'migrate');
    return this.http.request<TResult>(routes.migrate.run, {
      method: 'POST',
      body: input,
      apiKey: key,
      bearerToken: key,
    });
  }
}
