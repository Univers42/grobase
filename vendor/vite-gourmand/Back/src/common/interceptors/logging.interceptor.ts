/**
 * Logging Interceptor
 * Logs request/response details for debugging
 */
import {
  Injectable,
  NestInterceptor,
  ExecutionContext,
  CallHandler,
  Logger,
} from '@nestjs/common';
import { Observable } from 'rxjs';
import { tap } from 'rxjs/operators';
import { Request, Response } from 'express';

@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  private readonly logger = new Logger('HTTP');

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const request = context.switchToHttp().getRequest<Request>();
    const response = context.switchToHttp().getResponse<Response>();
    const startTime = Date.now();

    const { method, url, ip } = request;

    return next.handle().pipe(
      tap({
        next: () => this.logSuccess(method, url, ip, response, startTime),
        error: (error: unknown) =>
          this.logError(method, url, ip, error, startTime),
      }),
    );
  }

  private logSuccess(
    method: string,
    url: string,
    ip: string | undefined,
    response: Response,
    startTime: number,
  ): void {
    const duration = Date.now() - startTime;
    this.logger.log(
      `${method} ${url} ${response.statusCode} - ${duration}ms [${ip}]`,
    );
  }

  private logError(
    method: string,
    url: string,
    ip: string | undefined,
    error: unknown,
    startTime: number,
  ): void {
    const duration = Date.now() - startTime;
    const message = error instanceof Error ? error.message : String(error);
    this.logger.error(
      `${method} ${url} FAILED - ${duration}ms [${ip}]: ${message}`,
    );
  }
}
