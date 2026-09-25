import { Injectable, NestMiddleware } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import { Counter, Histogram, register } from 'prom-client';

type RequestMetricLabels = 'service' | 'method' | 'route' | 'status_code';

const LABELS: RequestMetricLabels[] = ['service', 'method', 'route', 'status_code'];

/** counter returns the process-wide counter `name`, creating it once. */
function counter(name: string, help: string): Counter<RequestMetricLabels> {
  const existing = register.getSingleMetric(name);
  if (existing instanceof Counter) return existing;
  return new Counter<RequestMetricLabels>({ name, help, labelNames: LABELS });
}

/** histogram returns the process-wide histogram `name`, creating it once. */
function histogram(name: string, help: string): Histogram<RequestMetricLabels> {
  const existing = register.getSingleMetric(name);
  if (existing instanceof Histogram) return existing;
  return new Histogram<RequestMetricLabels>({
    name,
    help,
    labelNames: LABELS,
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  });
}

/**
 * securityEvent names the security meaning of a status code, or undefined.
 * The value is a Loki label (promtail), so the set stays this small.
 */
export function securityEvent(status: number): string | undefined {
  switch (status) {
    case 401:
      return 'auth_failure';
    case 403:
      return 'access_denied';
    case 429:
      return 'rate_limited';
    default:
      return undefined;
  }
}

/**
 * RequestMetricsMiddleware counts and logs every response when it finishes —
 * including the 401s a middleware writes itself and the 401/403s a guard
 * throws, which an interceptor never sees because neither reaches it.
 * A request that matched no route is labelled `unrouted`, never with its raw
 * path, so a scanner cannot inflate the metric's cardinality.
 * It must run before any middleware that can answer a request, which is why
 * ObservabilityModule is global (Nest registers global modules' middleware first).
 */
@Injectable()
export class RequestMetricsMiddleware implements NestMiddleware {
  private readonly serviceName =
    process.env['OTEL_SERVICE_NAME'] ?? process.env['APP_NAME'] ?? 'unknown-service';
  private readonly requestCount = counter(
    'mini_baas_http_requests_total',
    'Total HTTP requests processed by mini-BaaS services.',
  );
  private readonly requestDuration = histogram(
    'mini_baas_http_request_duration_seconds',
    'HTTP request duration in seconds for mini-BaaS services.',
  );

  use(req: Request, res: Response, next: NextFunction): void {
    const started = process.hrtime.bigint();
    res.once('finish', () => this.record(req, res.statusCode, started));
    next();
  }

  /** record bumps the counter and histogram and writes one http_request line. */
  private record(req: Request, status: number, started: bigint): void {
    const route = typeof req.route?.path === 'string' ? req.route.path : 'unrouted';
    const labels = {
      service: this.serviceName,
      method: req.method,
      route,
      status_code: String(status),
    };
    const durationSeconds = Number(process.hrtime.bigint() - started) / 1_000_000_000;
    this.requestCount.inc(labels);
    this.requestDuration.observe(labels, durationSeconds);
    this.emitRequestLog(req, route, status, durationSeconds);
  }

  /** emitRequestLog writes the JSON line promtail ships and forwards it to log-service. */
  private emitRequestLog(
    req: Request,
    route: string,
    status: number,
    durationSeconds: number,
  ): void {
    const requestId = req.requestId ?? this.header(req, 'x-request-id');
    const data = {
      request_id: requestId,
      traceparent: this.header(req, 'traceparent'),
      method: req.method,
      route,
      status_code: status,
      duration_ms: Math.round(durationSeconds * 1000),
      event_type: securityEvent(status),
    };
    process.stdout.write(JSON.stringify({ service: this.serviceName, ...data }) + '\n');
    const logServiceUrl = process.env['LOG_SERVICE_URL'];
    if (!logServiceUrl || this.serviceName === 'log-service') return;
    const payload = {
      level: status >= 500 ? 'error' : 'info',
      source: this.serviceName,
      message: 'http_request',
      data,
    };
    void fetch(`${logServiceUrl.replace(/\/$/, '')}/logs/ingest`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).catch(() => undefined);
  }

  /** header returns the first value of request header `name`. */
  private header(req: Request, name: string): string | undefined {
    const value = req.headers[name];
    if (Array.isArray(value)) return value[0];
    return value;
  }
}
