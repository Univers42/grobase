import {
  Injectable,
  NestInterceptor,
  ExecutionContext,
  CallHandler,
  Logger,
} from '@nestjs/common';
import { Observable, tap, catchError, throwError } from 'rxjs';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { RequestLog, RequestLogDocument } from './schemas';

@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  private readonly logger = new Logger(LoggingInterceptor.name);

  constructor(
    @InjectModel(RequestLog.name)
    private requestLogModel: Model<RequestLogDocument>,
  ) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<any> {
    const ctx = context.switchToHttp();
    const request = ctx.getRequest();
    const start = Date.now();

    // Extract custom headers for platform analytics
    const platform = request.headers['x-platform'] as string | undefined;
    const deviceModel = request.headers['x-device-model'] as string | undefined;
    const appVersion = request.headers['x-app-version'] as string | undefined;

    return next.handle().pipe(
      tap(() => {
        const response = ctx.getResponse();
        this.saveLog({
          method: request.method,
          url: request.url,
          statusCode: response.statusCode,
          responseTime: Date.now() - start,
          userId: request.user?._id,
          ip: request.ip,
          userAgent: request.headers['user-agent'],
          platform,
          deviceModel,
          appVersion,
        });
      }),
      catchError((error) => {
        this.saveLog({
          method: request.method,
          url: request.url,
          statusCode: error.status || 500,
          responseTime: Date.now() - start,
          userId: request.user?._id,
          ip: request.ip,
          userAgent: request.headers['user-agent'],
          platform,
          deviceModel,
          appVersion,
          errorDetails: {
            message: error.message,
            name: error.name,
          },
        });
        return throwError(() => error);
      }),
    );
  }

  private saveLog(data: {
    method: string;
    url: string;
    statusCode: number;
    responseTime: number;
    userId?: string;
    ip?: string;
    userAgent?: string;
    platform?: string;
    deviceModel?: string;
    appVersion?: string;
    errorDetails?: Record<string, any>;
  }) {
    const log = new this.requestLogModel({
      ...data,
      userId: data.userId ? new Types.ObjectId(data.userId) : undefined,
    });

    // Non-blocking save — fire and forget
    log.save().catch((err) => {
      this.logger.error('Failed to save request log', err.message);
    });
  }
}
