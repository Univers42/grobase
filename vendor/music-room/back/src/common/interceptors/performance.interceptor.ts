import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
  Logger,
} from '@nestjs/common';
import { Observable, tap } from 'rxjs';

@Injectable()
export class PerformanceInterceptor implements NestInterceptor {
  private readonly logger = new Logger(PerformanceInterceptor.name);
  private readonly slowThresholdMs: number;

  constructor(slowThresholdMs = 3000) {
    this.slowThresholdMs = slowThresholdMs;
  }

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const request = context.switchToHttp().getRequest();
    const method = request.method;
    const url = request.url;
    const start = Date.now();

    return next.handle().pipe(
      tap(() => {
        const duration = Date.now() - start;
        if (duration > this.slowThresholdMs) {
          this.logger.warn(
            `Slow request: ${method} ${url} took ${duration}ms (threshold: ${this.slowThresholdMs}ms)`,
          );
        }
      }),
    );
  }
}
