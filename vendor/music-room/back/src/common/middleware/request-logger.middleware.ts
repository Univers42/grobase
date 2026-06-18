import { Injectable, NestMiddleware, Logger } from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';

@Injectable()
export class RequestLoggerMiddleware implements NestMiddleware {
  private readonly logger = new Logger('HTTP');

  use(req: Request, res: Response, next: NextFunction): void {
    const startTime = Date.now();
    const { method, originalUrl, ip } = req;
    const userAgent = req.get('user-agent') || '';

    res.on('finish', () => {
      const { statusCode } = res;
      const duration = Date.now() - startTime;
      const contentLength = res.get('content-length') || 0;

      const logMessage = `${method} ${originalUrl} ${statusCode} ${duration}ms ${contentLength}B`;

      if (statusCode >= 500) {
        this.logger.error(logMessage, { ip, userAgent });
      } else if (statusCode >= 400) {
        this.logger.warn(logMessage, { ip, userAgent });
      } else {
        this.logger.log(logMessage);
      }
    });

    next();
  }
}
