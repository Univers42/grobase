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

function firstHeader(value: HeaderValue): string | undefined {
  if (Array.isArray(value)) return value[0];
  return value;
}

export function createPinoHttpOptions(serviceName: string): Options {
  return {
    level: process.env['LOG_LEVEL'] ?? 'info',
    base: { service: serviceName },
    genReqId: (req: IncomingMessage, res: ServerResponse): string => {
      const requestId = firstHeader(req.headers['x-request-id']) ?? randomUUID();
      (req as IncomingMessage & { id?: string | number }).id = requestId;
      res.setHeader('X-Request-ID', requestId);
      return requestId;
    },
    customProps: (req: IncomingMessage) => ({
      request_id: (req as IncomingMessage & { id?: string | number }).id ?? firstHeader(req.headers['x-request-id']),
      traceparent: firstHeader(req.headers.traceparent),
    }),
  };
}