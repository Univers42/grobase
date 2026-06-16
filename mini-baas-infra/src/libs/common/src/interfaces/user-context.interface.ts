/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   user-context.interface.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

export type VerifiedAuthMethod = 'kong-hmac' | 'legacy-header' | 'service-token' | 'jwt' | 'mtls';

export interface VerifiedRequestIdentity {
  tenantId: string;
  projectId: string;
  appId: string;
  userId?: string;
  serviceId?: string;
  role: string;
  roleNames: string[];
  scopes: string[];
  authMethod: VerifiedAuthMethod;
}

/**
 * User context kept for compatibility while services migrate to CurrentIdentity.
 */
export interface UserContext {
  id: string;
  email: string;
  role: string;
  tenantId?: string;
  projectId?: string;
  appId?: string;
  scopes?: string[];
  authMethod?: VerifiedAuthMethod;
}

/**
 * Augment Express Request with user context.
 */
declare global {
  namespace Express {
    interface Request {
      user?: UserContext;
      identity?: VerifiedRequestIdentity;
      requestId?: string;
    }
  }
}
