/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   correlation-id.interceptor.ts                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import { trace } from '@opentelemetry/api';
import { randomUUID } from 'node:crypto';
import { Request, Response } from 'express';
import { Observable, tap } from 'rxjs';

/**
 * Reads X-Request-ID from inbound request (set by Kong),
 * falls back to a generated UUID, and propagates it onto the response.
 */
@Injectable()
export class CorrelationIdInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const req = context.switchToHttp().getRequest<Request>();
    const res = context.switchToHttp().getResponse<Response>();

    const correlationId = (req.headers['x-request-id'] as string) ?? randomUUID();
    req.requestId = correlationId;
    trace.getActiveSpan()?.setAttributes({
      request_id: correlationId,
      'http.request_id': correlationId,
    });
    if (!req.headers.traceparent) {
      req.headers.traceparent = this.traceparentFromRequestId(correlationId);
    }

    return next.handle().pipe(
      tap(() => {
        res.setHeader('X-Request-ID', correlationId);
        if (req.headers.traceparent) res.setHeader('traceparent', req.headers.traceparent);
      }),
    );
  }

  private traceparentFromRequestId(requestId: string): string {
    const traceId = requestId.replace(/[^a-fA-F0-9]/g, '').padEnd(32, '0').slice(0, 32);
    const spanId = randomUUID().replace(/[^a-fA-F0-9]/g, '').slice(0, 16);
    return `00-${traceId}-${spanId}-01`;
  }
}
