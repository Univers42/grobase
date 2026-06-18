/**
 * All Exceptions Filter
 * Catches any unhandled exceptions and formats them
 */
import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Response, Request } from 'express';

interface ErrorResponse {
  success: false;
  statusCode: number;
  message: string;
  error: string;
  path: string;
  timestamp: string;
}

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger(AllExceptionsFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<Request>();

    const { status, message, error } = this.parseException(exception);
    this.logException(exception, request, status);

    const errorResponse = this.buildErrorResponse(
      request,
      status,
      message,
      error,
    );
    response.status(status).json(errorResponse);
  }

  private parseException(exception: unknown): {
    status: number;
    message: string;
    error: string;
  } {
    if (exception instanceof HttpException) {
      return {
        status: exception.getStatus(),
        message: exception.message,
        error: exception.name,
      };
    }

    const isDev = process.env.NODE_ENV !== 'production';
    return {
      status: HttpStatus.INTERNAL_SERVER_ERROR,
      message:
        isDev && exception instanceof Error
          ? exception.message
          : 'Internal server error',
      error: 'InternalServerError',
    };
  }

  private logException(
    exception: unknown,
    request: Request,
    status: number,
  ): void {
    const message = exception instanceof Error ? exception.message : 'Unknown';
    this.logger.error(
      `[${request.method}] ${request.url} - ${status}: ${message}`,
      exception instanceof Error ? exception.stack : undefined,
    );
  }

  private buildErrorResponse(
    request: Request,
    status: number,
    message: string,
    error: string,
  ): ErrorResponse {
    return {
      success: false,
      statusCode: status,
      message,
      error,
      path: request.url,
      timestamp: new Date().toISOString(),
    };
  }
}
