/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   metrics.interceptor.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 16:10:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import type { Request, Response } from 'express';
import { Counter, Histogram, register } from 'prom-client';
import { Observable, catchError, finalize, throwError } from 'rxjs';

type RequestMetricLabels = 'service' | 'method' | 'route' | 'status_code';

function counter(name: string, help: string, labelNames: RequestMetricLabels[]): Counter<RequestMetricLabels> {
  const existing = register.getSingleMetric(name);
  if (existing instanceof Counter) return existing;
  return new Counter<RequestMetricLabels>({ name, help, labelNames });
}

function histogram(name: string, help: string, labelNames: RequestMetricLabels[]): Histogram<RequestMetricLabels> {
  const existing = register.getSingleMetric(name);
  if (existing instanceof Histogram) return existing;
  return new Histogram<RequestMetricLabels>({
    name,
    help,
    labelNames,
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  });
}

@Injectable()
export class MetricsInterceptor implements NestInterceptor {
  private readonly serviceName = process.env['OTEL_SERVICE_NAME'] ?? process.env['APP_NAME'] ?? 'unknown-service';
  private readonly requestCount = counter(
    'mini_baas_http_requests_total',
    'Total HTTP requests processed by mini-BaaS services.',
    ['service', 'method', 'route', 'status_code'],
  );
  private readonly requestDuration = histogram(
    'mini_baas_http_request_duration_seconds',
    'HTTP request duration in seconds for mini-BaaS services.',
    ['service', 'method', 'route', 'status_code'],
  );

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();

    const started = process.hrtime.bigint();
    const req = context.switchToHttp().getRequest<Request>();
    const res = context.switchToHttp().getResponse<Response>();
    let errorStatus: number | undefined;

    return next.handle().pipe(
      catchError((error: unknown) => {
        errorStatus = this.errorStatus(error);
        return throwError(() => error);
      }),
      finalize(() => {
        const statusCode = String(errorStatus ?? res.statusCode ?? 500);
        const labels = {
          service: this.serviceName,
          method: req.method,
          route: this.route(req),
          status_code: statusCode,
        };
        const durationSeconds = Number(process.hrtime.bigint() - started) / 1_000_000_000;
        this.requestCount.inc(labels);
        this.requestDuration.observe(labels, durationSeconds);
        this.emitRequestLog(req, statusCode, durationSeconds);
      }),
    );
  }

  private route(req: Request): string {
    const routePath = req.route?.path;
    if (typeof routePath === 'string') return routePath;
    return req.path ?? req.originalUrl ?? req.url ?? 'unknown';
  }

  private errorStatus(error: unknown): number {
    if (typeof error === 'object' && error !== null && 'getStatus' in error) {
      const getStatus = (error as { getStatus?: () => unknown }).getStatus;
      const status = typeof getStatus === 'function' ? getStatus.call(error) : undefined;
      if (typeof status === 'number') return status;
    }
    return 500;
  }

  private emitRequestLog(req: Request, statusCode: string, durationSeconds: number): void {
    const requestId = req.requestId ?? this.header(req, 'x-request-id');
    const payload = {
      level: Number(statusCode) >= 500 ? 'error' : 'info',
      source: this.serviceName,
      message: 'http_request',
      data: {
        request_id: requestId,
        traceparent: this.header(req, 'traceparent'),
        method: req.method,
        route: this.route(req),
        status_code: Number(statusCode),
        duration_ms: Math.round(durationSeconds * 1000),
      },
    };
    console.log(JSON.stringify({ service: this.serviceName, ...payload.data, request_id: requestId }));
    const logServiceUrl = process.env['LOG_SERVICE_URL'];
    if (!logServiceUrl || this.serviceName === 'log-service') return;
    void fetch(`${logServiceUrl.replace(/\/$/, '')}/logs/ingest`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).catch(() => undefined);
  }

  private header(req: Request, name: string): string | undefined {
    const value = req.headers[name];
    if (Array.isArray(value)) return value[0];
    return value;
  }
}