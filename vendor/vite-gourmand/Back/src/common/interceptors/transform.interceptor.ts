/**
 * Transform Interceptor
 * Wraps successful responses in consistent API format
 */
import {
  Injectable,
  NestInterceptor,
  ExecutionContext,
  CallHandler,
} from '@nestjs/common';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';
import { Request, Response } from 'express';

export interface ApiResponse<T> {
  success: true;
  statusCode: number;
  message: string;
  data: T;
  path: string;
  timestamp: string;
}

@Injectable()
export class TransformInterceptor<T> implements NestInterceptor<
  T,
  ApiResponse<T>
> {
  intercept(
    context: ExecutionContext,
    next: CallHandler<T>,
  ): Observable<ApiResponse<T>> {
    const request = context.switchToHttp().getRequest<Request>();
    const response = context.switchToHttp().getResponse<Response>();

    return next
      .handle()
      .pipe(map((data) => this.transform(data, request, response)));
  }

  private transform(
    data: T,
    request: Request,
    response: Response,
  ): ApiResponse<T> {
    return {
      success: true,
      statusCode: response.statusCode,
      message: this.getMessage(request.method, response.statusCode),
      data,
      path: request.url,
      timestamp: new Date().toISOString(),
    };
  }

  private getMessage(method: string, statusCode: number): string {
    const messages: Record<string, Record<number, string>> = {
      GET: { 200: 'Data retrieved successfully' },
      POST: {
        201: 'Resource created successfully',
        200: 'Operation successful',
      },
      PUT: { 200: 'Resource updated successfully' },
      PATCH: { 200: 'Resource updated successfully' },
      DELETE: { 200: 'Resource deleted successfully' },
    };

    return messages[method]?.[statusCode] ?? 'Operation successful';
  }
}
