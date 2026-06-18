/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   all-exceptions.filter.ts                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Request, Response } from 'express';

/** Normalised error shape resolved from any thrown exception. */
interface NormalizedError {
  status: number;
  message: string | string[];
  error: string;
}

const INTERNAL: NormalizedError = {
  status: HttpStatus.INTERNAL_SERVER_ERROR,
  message: 'Internal server error',
  error: 'Internal Server Error',
};

/**
 * Global exception filter that normalises every error into a consistent JSON shape:
 * { statusCode, error, message, requestId?, timestamp }
 */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger(AllExceptionsFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse<Response>();
    const req = ctx.getRequest<Request>();

    const { status, message, error } = this.normalize(exception);

    res.status(status).json({
      statusCode: status,
      error,
      message,
      requestId: req.requestId,
      timestamp: new Date().toISOString(),
    });
  }

  private normalize(exception: unknown): NormalizedError {
    if (exception instanceof HttpException) return this.fromHttpException(exception);
    if (exception instanceof Error) return this.fromError(exception);
    this.logger.error('Unknown exception', exception);
    return INTERNAL;
  }

  private fromHttpException(exception: HttpException): NormalizedError {
    const status = exception.getStatus();
    const body = exception.getResponse();
    if (typeof body === 'string') {
      return { status, message: body, error: HttpStatus[status] ?? 'Error' };
    }
    const obj = body as Record<string, unknown>;
    return {
      status,
      message: (obj['message'] as string | string[]) ?? exception.message,
      error: (obj['error'] as string) ?? HttpStatus[status] ?? 'Error',
    };
  }

  private fromError(exception: Error): NormalizedError {
    // Some framework/runtime errors carry an HTTP-meaningful status without being
    // an HttpException — e.g. body-parser PayloadTooLargeError (413) and malformed
    // JSON (400). Those are the CLIENT's fault: surface them cleanly as the 4xx they
    // are instead of masking them as a 500. Anything without a 4xx status stays 500
    // (so genuine server bugs are NOT hidden).
    const carried = carriedClientStatus(exception);
    if (carried !== undefined) {
      return {
        status: carried,
        error: HttpStatus[carried] ?? 'Error',
        message: exception.message || (HttpStatus[carried] ?? 'Error'),
      };
    }
    this.logger.error(`Unhandled: ${exception.message}`, exception.stack);
    return INTERNAL;
  }
}

/**
 * Resolve the carried 4xx status from a non-HttpException error, or `undefined`
 * when the error does not carry a client-fault (4xx) status.
 */
function carriedClientStatus(exception: Error): number | undefined {
  const anyErr = exception as unknown as {
    statusCode?: unknown;
    status?: unknown;
    type?: unknown;
  };
  let carried: number | undefined;
  if (typeof anyErr.statusCode === 'number') carried = anyErr.statusCode;
  else if (typeof anyErr.status === 'number') carried = anyErr.status;
  else if (anyErr.type === 'entity.too.large') carried = 413;
  else if (anyErr.type === 'entity.parse.failed') carried = 400;

  if (typeof carried === 'number' && carried >= 400 && carried < 500) return carried;
  return undefined;
}
