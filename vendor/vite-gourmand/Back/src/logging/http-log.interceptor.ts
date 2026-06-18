/**
 * HTTP Log Interceptor
 */
import {
  Injectable,
  NestInterceptor,
  ExecutionContext,
  CallHandler,
  Logger,
  Inject,
  Optional,
} from '@nestjs/common';
import { Observable, tap } from 'rxjs';
import { Request, Response } from 'express';
import { LogService } from './log.service';

@Injectable()
export class HttpLogInterceptor implements NestInterceptor {
  private readonly logger = new Logger('HTTP');

  constructor(
    @Optional() @Inject(LogService) private readonly logService?: LogService,
  ) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const ctx = context.switchToHttp();
    const request = ctx.getRequest<Request>();
    const response = ctx.getResponse<Response>();

    const { method, url, ip } = request;
    const userAgent = request.get('user-agent') || '';
    const clientIp = ip || 'unknown';
    const startTime = Date.now();

    return next.handle().pipe(
      tap({
        next: () =>
          this.logSuccess(
            method,
            url,
            response.statusCode,
            startTime,
            clientIp,
            userAgent,
          ),
        error: (error: unknown) => {
          const statusCode =
            typeof error === 'object' &&
            error !== null &&
            'status' in error &&
            typeof error.status === 'number'
              ? error.status
              : 500;
          const errorMessage =
            error instanceof Error ? error.message : String(error);

          return this.logError(
            method,
            url,
            statusCode,
            startTime,
            clientIp,
            userAgent,
            errorMessage,
          );
        },
      }),
    );
  }

  private logSuccess(
    method: string,
    url: string,
    statusCode: number,
    startTime: number,
    ip: string,
    userAgent: string,
  ): void {
    const duration = Date.now() - startTime;
    this.logger.log(
      `${method} ${url} ${statusCode} ${duration}ms - ${ip} "${userAgent}"`,
    );

    // Store in log service for streaming
    if (this.logService) {
      this.logService.logHttp(method, url, statusCode, duration, ip);
    }
  }

  private logError(
    method: string,
    url: string,
    statusCode: number,
    startTime: number,
    ip: string,
    userAgent: string,
    errorMessage?: string,
  ): void {
    const duration = Date.now() - startTime;
    this.logger.error(
      `${method} ${url} ${statusCode} ${duration}ms - ${ip} "${userAgent}"`,
    );

    // Store in log service for streaming
    if (this.logService) {
      this.logService.logHttp(
        method,
        url,
        statusCode,
        duration,
        ip,
        errorMessage,
      );
    }
  }
}
