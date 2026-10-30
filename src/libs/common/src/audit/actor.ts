/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   actor.ts                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 11:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 11:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import type { VerifiedRequestIdentity } from '../interfaces/user-context.interface';
import { isUuid } from './request-id';

export interface AuditActor {
  actorId: string | null;
  actorRole: string | null;
}

const KONG_USER_PREFIX = 'user:';

function uuidOrNull(value: string | undefined): string | null {
  return value !== undefined && isUuid(value) ? value : null;
}

/**
 * The `audit_log` actor for a verified identity (ADR 0020). `actor_id` is a
 * GoTrue user sub or NULL — never an API key, tenant or service id — because
 * `audit_log_self_read` matches it against the JWT `sub`. Built from the
 * identity, not `req.user.id`, which falls back to the tenant id.
 */
export function auditActor(identity: VerifiedRequestIdentity | undefined): AuditActor {
  if (!identity) return { actorId: null, actorRole: null };
  switch (identity.authMethod) {
    case 'kong-hmac': {
      // HMAC-signed by the gateway: `user:<sub>` when a verified user JWT rode
      // with the app key, `api-key:<keyId>` otherwise.
      const userId = identity.userId ?? '';
      const sub = userId.startsWith(KONG_USER_PREFIX)
        ? userId.slice(KONG_USER_PREFIX.length)
        : undefined;
      return { actorId: uuidOrNull(sub), actorRole: identity.role };
    }
    case 'jwt':
      return { actorId: uuidOrNull(identity.userId), actorRole: identity.role };
    case 'legacy-header':
      // Unsigned header: only a bare UUID counts, never a stripped `user:` prefix.
      return { actorId: uuidOrNull(identity.userId), actorRole: identity.role };
    case 'service-token':
      return { actorId: null, actorRole: 'service_role' };
    default:
      return { actorId: null, actorRole: null };
  }
}
