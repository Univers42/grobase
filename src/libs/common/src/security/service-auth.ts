/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service-auth.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

/**
 * v1 HMAC service-to-service auth (audit O1) — the TS caller half of the Go
 * `shared.VerifyServiceRequest`. Under SERVICE_TOKEN_MODE=hmac the shared token
 * never transits the wire; each request carries
 *
 *   X-Service-Auth: v1.<ts>.<hex hmac-sha256(token, "<ts>\n<METHOD>\n<PATH>\n<sha256hex(body)>")>
 *
 * binding time, method, path and body. PATH is the URL path only (internal
 * base URLs are origin-only; these routes take no query strings). Golden
 * vectors live in shared/token_test.go + service_auth.rs — the three languages
 * sign byte-identically.
 */
export function serviceAuthHmacMode(): boolean {
  return (process.env.SERVICE_TOKEN_MODE ?? '').trim().toLowerCase() === 'hmac';
}

export function computeServiceAuth(
  token: string,
  method: string,
  path: string,
  body: string | Buffer = '',
  ts: number = Math.floor(Date.now() / 1000),
): string {
  const bodyHex = createHash('sha256').update(body).digest('hex');
  const msg = `${ts}\n${method.toUpperCase()}\n${path}\n${bodyHex}`;
  const sig = createHmac('sha256', token).update(msg).digest('hex');
  return `v1.${ts}.${sig}`;
}

/** Auth headers for an internal call: signed in hmac mode, static otherwise. */
export function serviceAuthHeaders(
  token: string,
  method: string,
  path: string,
  body: string | Buffer = '',
): Record<string, string> {
  return serviceAuthHmacMode()
    ? { 'X-Service-Auth': computeServiceAuth(token, method, path, body) }
    : { 'X-Service-Token': token };
}

/** Constant-time string equality (length-safe). */
export function timingSafeStringEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}
