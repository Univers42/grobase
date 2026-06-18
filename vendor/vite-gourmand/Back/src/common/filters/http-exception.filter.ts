/**
 * HTTP Exception Filter
 * Formats HTTP exceptions into consistent response structure
 */
import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
} from '@nestjs/common';
import { Response, Request } from 'express';

interface ErrorResponse {
  success: false;
  statusCode: number;
  message: string;
  error: string;
  path: string;
  timestamp: string;
  details?: unknown;
}

@Catch(HttpException)
export class HttpExceptionFilter implements ExceptionFilter {
  catch(exception: HttpException, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<Request>();
    const status = exception.getStatus();

    const errorResponse = this.buildErrorResponse(exception, request, status);
    response.status(status).json(errorResponse);
  }

  private buildErrorResponse(
    exception: HttpException,
    request: Request,
    status: number,
  ): ErrorResponse {
    const exceptionResponse = exception.getResponse();
    const { message, error, details } = this.parseExceptionResponse(
      exceptionResponse,
      exception,
    );

    const baseResponse: ErrorResponse = {
      success: false,
      statusCode: status,
      message,
      error,
      path: request.url,
      timestamp: new Date().toISOString(),
    };

    if (details) {
      baseResponse.details = details;
    }

    return baseResponse;
  }

  private parseExceptionResponse(
    response: unknown,
    exception: HttpException,
  ): { message: string; error: string; details?: unknown } {
    if (typeof response === 'object' && response !== null) {
      const resp = response as Record<string, unknown>;
      const msg = resp.message;
      const err = resp.error;
      return {
        message: typeof msg === 'string' ? msg : exception.message,
        error: typeof err === 'string' ? err : 'Error',
        details: resp.details,
      };
    }
    return { message: exception.message, error: 'Error' };
  }
}
