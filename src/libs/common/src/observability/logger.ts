/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   logger.ts                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 16:10:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import type { IncomingMessage, ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';
import type { Options } from 'pino-http';

type HeaderValue = string | string[] | undefined;

/**
 * Headers that carry a credential, at the paths pino-http serialises them to.
 * Node lowercases incoming header names, so one spelling covers every client
 * casing. On 2026-10-15 query-router's log on the b2b VM held a raw Bearer JWT
 * and apikey for request #1041, and promtail ships these lines to Loki.
 * ponytail: a denylist — a credential in an unlisted header, the URL query or a
 * body is still logged; add its path here, and to m230, when one appears.
 */
const CREDENTIAL_PATHS: readonly string[] = [
  'req.headers.authorization',
  'req.headers.apikey',
  'req.headers["x-baas-api-key"]',
  'req.headers["x-service-token"]',
  'req.headers["x-service-auth"]',
  'req.headers.cookie',
  'res.headers["set-cookie"]',
];

function firstHeader(value: HeaderValue): string | undefined {
  if (Array.isArray(value)) return value[0];
  return value;
}

export function createPinoHttpOptions(serviceName: string): Options {
  return {
    level: process.env['LOG_LEVEL'] ?? 'info',
    base: { service: serviceName },
    redact: { paths: [...CREDENTIAL_PATHS], censor: '[REDACTED]' },
    genReqId: (req: IncomingMessage, res: ServerResponse): string => {
      const requestId = firstHeader(req.headers['x-request-id']) ?? randomUUID();
      (req as IncomingMessage & { id?: string | number }).id = requestId;
      res.setHeader('X-Request-ID', requestId);
      return requestId;
    },
    customProps: (req: IncomingMessage) => ({
      request_id:
        (req as IncomingMessage & { id?: string | number }).id ??
        firstHeader(req.headers['x-request-id']),
      traceparent: firstHeader(req.headers.traceparent),
    }),
  };
}
