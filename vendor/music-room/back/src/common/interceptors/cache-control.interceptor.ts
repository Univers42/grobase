import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
  Logger,
} from '@nestjs/common';
import { Observable, tap } from 'rxjs';
import { Response } from 'express';

@Injectable()
export class CacheControlInterceptor implements NestInterceptor {
  private readonly maxAge: number;

  constructor(maxAge = 0) {
    this.maxAge = maxAge;
  }

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    return next.handle().pipe(
      tap(() => {
        const response = context.switchToHttp().getResponse<Response>();

        if (this.maxAge > 0) {
          response.setHeader(
            'Cache-Control',
            `public, max-age=${this.maxAge}, s-maxage=${this.maxAge}`,
          );
        } else {
          response.setHeader(
            'Cache-Control',
            'no-store, no-cache, must-revalidate, proxy-revalidate',
          );
          response.setHeader('Pragma', 'no-cache');
          response.setHeader('Expires', '0');
        }
      }),
    );
  }
}
