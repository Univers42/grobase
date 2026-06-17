/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   transform.interceptor.ts                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Injectable,
  NestInterceptor,
  ExecutionContext,
  CallHandler,
} from '@nestjs/common';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';
import { Request, Response } from 'express';

/**
 * Standard success response envelope.
 * Pairs with AllExceptionsFilter which wraps errors.
 */
export interface ApiSuccessResponse<T> {
  success: true;
  statusCode: number;
  message: string;
  data: T;
  path: string;
  timestamp: string;
}

const METHOD_MESSAGES: Record<string, Record<number, string>> = {
  GET: { 200: 'Data retrieved successfully' },
  POST: { 201: 'Resource created successfully', 200: 'Operation successful' },
  PUT: { 200: 'Resource updated successfully' },
  PATCH: { 200: 'Resource updated successfully' },
  DELETE: { 200: 'Resource deleted successfully' },
};

/**
 * Wraps every successful response in { success: true, data, statusCode, message, path, timestamp }.
 * Use as global interceptor: `app.useGlobalInterceptors(new TransformInterceptor())`.
 */
@Injectable()
export class TransformInterceptor<T>
  implements NestInterceptor<T, ApiSuccessResponse<T> | T>
{
  intercept(
    context: ExecutionContext,
    next: CallHandler<T>,
  ): Observable<ApiSuccessResponse<T> | T> {
    const req = context.switchToHttp().getRequest<Request>();
    const res = context.switchToHttp().getResponse<Response>();

    if (req.path === '/metrics' || req.url === '/metrics' || req.url.startsWith('/metrics?')) {
      return next.handle();
    }

    return next.handle().pipe(
      map((data) => ({
        success: true as const,
        statusCode: res.statusCode,
        message:
          METHOD_MESSAGES[req.method]?.[res.statusCode] ??
          'Operation successful',
        data,
        path: req.url,
        timestamp: new Date().toISOString(),
      })),
    );
  }
}
