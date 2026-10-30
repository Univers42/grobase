/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   request-id.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 09:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 09:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { createHash } from 'node:crypto';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Fixed so the same X-Request-ID maps to the same id in audit_log, the outbox
// and any later recomputation from a logged header. Never change it.
const REQUEST_ID_NAMESPACE = '3b7c2f4e-6a1d-4c8e-9f05-2d6e8a4b1c97';

export function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}

/** RFC 4122 §4.3 name-based UUID (version 5, SHA-1). */
export function uuidV5(name: string, namespace: string): string {
  const ns = Buffer.from(namespace.replace(/-/g, ''), 'hex');
  const bytes = createHash('sha1').update(ns).update(name, 'utf8').digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/**
 * The uuid-typed `request_id` stored for an X-Request-ID. Kong's `uuid#counter`
 * generator keeps one UUID per worker and appends a counter, so stripping the
 * suffix would merge every request a worker served; anything that is not a
 * bare UUID is hashed whole instead (ADR 0018).
 *
 * Caveat: the header is client-asserted (Kong keeps an inbound X-Request-ID), so
 * the id correlates rows, it does not authenticate them. Two different headers
 * collide only on a SHA-1 collision. Join a log line back by recomputing
 * `requestIdUuid(<logged header>)`.
 */
export function requestIdUuid(raw: string): string {
  return isUuid(raw) ? raw : uuidV5(raw, REQUEST_ID_NAMESPACE);
}
