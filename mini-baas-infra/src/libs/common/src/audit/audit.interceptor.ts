/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit.interceptor.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 21:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import type { Request } from 'express';
import { Observable, tap } from 'rxjs';
import { AuditService } from './audit.service';

const MUTATING_METHODS = new Set(['POST', 'PATCH', 'PUT', 'DELETE']);

/**
 * Writes one `audit_log` row per mutating HTTP request, after the handler
 * succeeds. Skips non-mutating verbs (GET / HEAD / OPTIONS) and skips
 * requests that fail before they reach the handler (auth, validation, etc.).
 *
 * Depends on:
 *  - `CorrelationIdInterceptor` having populated `req.requestId`
 *  - `AuthGuard` having populated `req.user` (optional — anonymous mutations
 *    are still recorded with `actor_id = NULL`)
 *
 * Register globally per-service via the {@link AuditModule}.
 */
@Injectable()
export class AuditInterceptor implements NestInterceptor {
  constructor(private readonly audit: AuditService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();
    const req = context.switchToHttp().getRequest<Request>();
    if (!MUTATING_METHODS.has(req.method)) return next.handle();

    const requestId = req.requestId ?? (req.headers['x-request-id'] as string | undefined);
    if (!requestId) return next.handle();

    const ip = (
      (req.headers['x-forwarded-for'] as string | undefined)?.split(',')[0]?.trim() ??
      req.ip ??
      req.socket?.remoteAddress ??
      null
    );

    return next.handle().pipe(
      tap(() => {
        // Fire-and-forget: never block the response on the audit write.
        void this.audit.record({
          requestId,
          actorId: req.user?.id ?? null,
          actorRole: req.user?.role ?? null,
          action: req.method,
          resource: req.originalUrl || req.url,
          payload: this.summarizeBody(req.body),
          ip,
          userAgent: (req.headers['user-agent'] as string | undefined) ?? null,
        });
      }),
    );
  }

  private summarizeBody(body: unknown): unknown {
    if (body == null) return undefined;
    try {
      const serialized = JSON.stringify(body);
      // Cap at 8 KB to avoid bloating audit_log on bulk payloads.
      if (serialized.length > 8 * 1024) return { truncated: true, size: serialized.length };
      return body;
    } catch {
      return { unserializable: true };
    }
  }
}
