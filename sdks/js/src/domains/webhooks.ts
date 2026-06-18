/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   webhooks.ts                                        :+:      :+:    :+:   */
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
  WebhookCreateInput,
  WebhookDelivery,
  WebhookSubscription,
  WebhookUpdateInput,
} from '../types.js';

/**
 * Tenant-scoped webhook subscription registry (`/admin/v1/webhooks`).
 *
 * **Admin-only / server-side.** This surface is internal-only at the gateway
 * (ip-restriction + service token); callers must construct the client with a
 * `serviceRoleKey`. Never ship a webhook secret to a browser. Secrets are
 * write-only and are never returned by `list`/`get`.
 */
export class WebhooksClient {
  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {}

  /** List the calling tenant's webhook subscriptions. */
  list(): Promise<WebhookSubscription[]> {
    return this.request<WebhookSubscription[]>(routes.webhooks.root, 'GET');
  }

  /** Create a webhook subscription. */
  create(input: WebhookCreateInput): Promise<WebhookSubscription> {
    return this.request<WebhookSubscription>(routes.webhooks.root, 'POST', input);
  }

  /** Fetch a single subscription by id. */
  get(id: string): Promise<WebhookSubscription> {
    return this.request<WebhookSubscription>(routes.webhooks.one(id), 'GET');
  }

  /** Patch a subscription. */
  update(id: string, input: WebhookUpdateInput): Promise<WebhookSubscription> {
    return this.request<WebhookSubscription>(routes.webhooks.one(id), 'PATCH', input);
  }

  /** Delete a subscription. */
  delete(id: string): Promise<{ deleted: boolean }> {
    return this.request<{ deleted: boolean }>(routes.webhooks.one(id), 'DELETE');
  }

  /** Read the recent delivery ledger for a subscription. */
  deliveries(id: string, limit = 50): Promise<WebhookDelivery[]> {
    return this.request<WebhookDelivery[]>(`${routes.webhooks.deliveries(id)}?limit=${limit}`, 'GET');
  }

  private request<TResult>(path: string, method: string, body?: unknown): Promise<TResult> {
    const key = requireAdminKey(this.serviceRoleKey, 'webhooks');
    return this.http.request<TResult>(path, { method, body, apiKey: key, bearerToken: key });
  }
}
