import { Injectable, NestMiddleware } from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';

/**
 * Middleware that sanitizes incoming request bodies to prevent
 * NoSQL injection and XSS attacks.
 *
 * Strips:
 * - MongoDB operators ($gt, $gte, $lt, $ne, $in, $regex, etc.)
 * - HTML/script tags from string values
 * - __proto__, constructor, prototype pollution keys
 */
@Injectable()
export class SanitizeMiddleware implements NestMiddleware {
  use(req: Request, _res: Response, next: NextFunction) {
    if (req.body && typeof req.body === 'object') {
      req.body = this.sanitize(req.body);
    }
    if (req.query && typeof req.query === 'object') {
      req.query = this.sanitize(req.query as Record<string, any>);
    }
    next();
  }

  private sanitize(obj: any): any {
    if (obj === null || obj === undefined) return obj;

    if (typeof obj === 'string') {
      return this.sanitizeString(obj);
    }

    if (Array.isArray(obj)) {
      return obj.map((item) => this.sanitize(item));
    }

    if (typeof obj === 'object') {
      const cleaned: Record<string, any> = {};

      for (const [key, value] of Object.entries(obj)) {
        // Block prototype pollution
        if (['__proto__', 'constructor', 'prototype'].includes(key)) {
          continue;
        }

        // Block MongoDB operators
        if (key.startsWith('$')) {
          continue;
        }

        cleaned[key] = this.sanitize(value);
      }

      return cleaned;
    }

    return obj;
  }

  private sanitizeString(str: string): string {
    // Remove HTML tags
    let cleaned = str.replace(/<[^>]*>/g, '');

    // Escape common XSS characters
    cleaned = cleaned
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#x27;');

    return cleaned;
  }
}
