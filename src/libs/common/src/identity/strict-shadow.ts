/**
 * IDENTITY_STRICT_SHADOW — what IDENTITY_HEADER_MODE=strict would refuse, measured on
 * live compat traffic before anyone flips it (ADR 0023 precondition 2, devil SS1–SS12).
 *
 * Compat accepts raw X-User-* headers; strict ignores them and judges the request on its
 * bearer JWT alone. For every routed request compat accepts on raw headers, this runs the
 * strict judge and records whether strict would accept it with the same identity. It only
 * observes: it never throws, never awaits, never touches the request, and the caller
 * returns the compat identity whatever it finds.
 *
 * Caveat: only requests that reach a route are judged (`req.route` is set). A resolve
 * from app-level middleware — mongo-api's body-size peek — is skipped, so it is never
 * double-counted, and a request rejected before routing is never counted at all: the
 * would_reject total under-reports for those. The log is rate limited per key, so the
 * counter, not the log, is the volume.
 */
import { Logger } from '@nestjs/common';
import { Counter, register } from 'prom-client';
import type { VerifiedRequestIdentity } from '../interfaces/user-context.interface';
import { envFlag } from './env-flag';
import { bearerToken } from './user-jwt';

export interface ShadowRequest {
  headers: Record<string, string | string[] | undefined>;
  route?: { path?: unknown };
}

/** The strict-mode resolve of the same request, passed in so it runs only when judged. */
export type StrictJudge = () => VerifiedRequestIdentity | undefined;

type Reason = 'no_bearer' | 'bearer_invalid' | 'unverifiable' | 'mismatch';

interface Verdict {
  reason?: Reason;
  fields: string[];
}

const COMPARED = [
  'userId',
  'tenantId',
  'projectId',
  'role',
  'roleNames',
  'scopes',
  'appId',
] as const satisfies readonly (keyof VerifiedRequestIdentity)[];

const METRIC = 'mini_baas_identity_strict_shadow_total';
const LOG_EVERY_MS = 60_000;
// Caveat: the rate-limit map holds 512 keys and evicts the oldest; a service with more
// distinct route×reason×fields keys than that logs an evicted key again within 60 s.
const LOG_KEYS_MAX = 512;
const lastLogged = new Map<string, number>();
const logger = new Logger('IdentityStrictShadow');

/**
 * Returns `compat` unchanged. Under IDENTITY_STRICT_SHADOW=1, on a routed request, first
 * judges it against strict mode and records the verdict; otherwise `judge` is never called.
 */
export function shadowStrict(
  req: ShadowRequest,
  compat: VerifiedRequestIdentity,
  judge: StrictJudge,
): VerifiedRequestIdentity {
  const route = req.route?.path;
  if (!envFlag('IDENTITY_STRICT_SHADOW') || typeof route !== 'string') return compat;
  const verdict = judgeStrict(req, compat, judge);
  const service = serviceName();
  shadowCounter().inc({
    service,
    result: verdict.reason ? 'would_reject' : 'would_accept',
    reason: verdict.reason ?? 'match',
  });
  if (verdict.reason) logWouldReject(service, route, verdict, Date.now());
  return compat;
}

function judgeStrict(
  req: ShadowRequest,
  compat: VerifiedRequestIdentity,
  judge: StrictJudge,
): Verdict {
  let strict: VerifiedRequestIdentity | undefined;
  try {
    strict = judge();
  } catch {
    // The judge throws on a config strict cannot run with (GOTRUE_JWT_ISSUER empty):
    // strict would refuse every request, which is exactly what this reports.
    return { reason: 'unverifiable', fields: [] };
  }
  if (!strict) {
    const hasBearer = bearerToken(firstHeader(req.headers['authorization'])) !== undefined;
    return { reason: hasBearer ? 'bearer_invalid' : 'no_bearer', fields: [] };
  }
  const fields = COMPARED.filter((field) => !sameValue(compat[field], strict[field]));
  return fields.length > 0 ? { reason: 'mismatch', fields } : { fields };
}

function logWouldReject(service: string, route: string, verdict: Verdict, now: number): void {
  const fields = verdict.fields.join(',');
  const key = `${route}|${verdict.reason}|${fields}`;
  const last = lastLogged.get(key);
  if (last !== undefined && now - last < LOG_EVERY_MS) return;
  lastLogged.delete(key);
  lastLogged.set(key, now);
  if (lastLogged.size > LOG_KEYS_MAX) lastLogged.delete(lastLogged.keys().next().value as string);
  const suffix = fields ? ` fields=${fields}` : '';
  logger.warn(
    `identity: would_reject service=${service} route=${route} reason=${verdict.reason}${suffix}`,
  );
}

function sameValue(left: unknown, right: unknown): boolean {
  if (Array.isArray(left) && Array.isArray(right)) {
    return left.length === right.length && left.every((entry, index) => entry === right[index]);
  }
  return left === right;
}

function firstHeader(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function serviceName(): string {
  return process.env['OTEL_SERVICE_NAME'] ?? process.env['APP_NAME'] ?? 'unknown-service';
}

function shadowCounter(): Counter<'service' | 'result' | 'reason'> {
  const existing = register.getSingleMetric(METRIC);
  if (existing) return existing as Counter<'service' | 'result' | 'reason'>;
  return new Counter({
    name: METRIC,
    help: 'Compat-accepted raw-header requests judged against IDENTITY_HEADER_MODE=strict',
    labelNames: ['service', 'result', 'reason'],
  });
}

/** Test seam: forget the rate-limit state. */
export function resetStrictShadowForTest(): void {
  lastLogged.clear();
}
