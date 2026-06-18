import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { MongoError } from 'mongodb';
import { Response } from 'express';

@Catch(MongoError)
export class MongoExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger(MongoExceptionFilter.name);

  catch(exception: MongoError, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();

    let status = HttpStatus.INTERNAL_SERVER_ERROR;
    let message = 'Database error';

    switch (exception.code) {
      case 11000:
        status = HttpStatus.CONFLICT;
        message = this.extractDuplicateKeyMessage(exception);
        break;
      case 121:
        status = HttpStatus.BAD_REQUEST;
        message = 'Document validation failed';
        break;
      default:
        this.logger.error(
          `MongoDB error (code: ${exception.code}): ${exception.message}`,
          exception.stack,
        );
    }

    response.status(status).json({
      statusCode: status,
      timestamp: new Date().toISOString(),
      error: status === HttpStatus.CONFLICT ? 'Conflict' : 'Database Error',
      message,
    });
  }

  private extractDuplicateKeyMessage(exception: MongoError): string {
    const messageStr = exception.message || '';
    const match = messageStr.match(/dup key: \{ (\w+):/);
    if (match) {
      return `A record with this ${match[1]} already exists`;
    }
    return 'Duplicate key error';
  }
}
