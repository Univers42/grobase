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

    let status: number;
    let message: string | string[];
    let error: string;

    if (exception instanceof HttpException) {
      status = exception.getStatus();
      const body = exception.getResponse();
      if (typeof body === 'string') {
        message = body;
        error = HttpStatus[status] ?? 'Error';
      } else {
        const obj = body as Record<string, unknown>;
        message = (obj['message'] as string | string[]) ?? exception.message;
        error = (obj['error'] as string) ?? HttpStatus[status] ?? 'Error';
      }
    } else if (exception instanceof Error) {
      // Some framework/runtime errors carry an HTTP-meaningful status without being
      // an HttpException — e.g. body-parser PayloadTooLargeError (413) and malformed
      // JSON (400). Those are the CLIENT's fault: surface them cleanly as the 4xx they
      // are instead of masking them as a 500. Anything without a 4xx status stays 500
      // (so genuine server bugs are NOT hidden).
      const anyErr = exception as unknown as {
        statusCode?: unknown;
        status?: unknown;
        type?: unknown;
      };
      const carried =
        typeof anyErr.statusCode === 'number'
          ? anyErr.statusCode
          : typeof anyErr.status === 'number'
            ? anyErr.status
            : anyErr.type === 'entity.too.large'
              ? 413
              : anyErr.type === 'entity.parse.failed'
                ? 400
                : undefined;
      if (typeof carried === 'number' && carried >= 400 && carried < 500) {
        status = carried;
        error = HttpStatus[status] ?? 'Error';
        message = exception.message || error;
      } else {
        status = HttpStatus.INTERNAL_SERVER_ERROR;
        message = 'Internal server error';
        error = 'Internal Server Error';
        this.logger.error(`Unhandled: ${exception.message}`, exception.stack);
      }
    } else {
      status = HttpStatus.INTERNAL_SERVER_ERROR;
      message = 'Internal server error';
      error = 'Internal Server Error';
      this.logger.error('Unknown exception', exception);
    }

    res.status(status).json({
      statusCode: status,
      error,
      message,
      requestId: req.requestId,
      timestamp: new Date().toISOString(),
    });
  }
}
