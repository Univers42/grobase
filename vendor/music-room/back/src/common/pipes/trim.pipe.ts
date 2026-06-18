import { PipeTransform, Injectable, BadRequestException } from '@nestjs/common';

@Injectable()
export class TrimPipe implements PipeTransform {
  transform(value: unknown): unknown {
    if (typeof value === 'string') {
      return value.trim();
    }
    if (typeof value === 'object' && value !== null) {
      return this.trimObject(value as Record<string, unknown>);
    }
    return value;
  }

  private trimObject(obj: Record<string, unknown>): Record<string, unknown> {
    const trimmed: Record<string, unknown> = {};
    for (const [key, val] of Object.entries(obj)) {
      if (typeof val === 'string') {
        trimmed[key] = val.trim();
      } else if (typeof val === 'object' && val !== null && !Array.isArray(val)) {
        trimmed[key] = this.trimObject(val as Record<string, unknown>);
      } else if (Array.isArray(val)) {
        trimmed[key] = val.map((item) =>
          typeof item === 'string' ? item.trim() : item,
        );
      } else {
        trimmed[key] = val;
      }
    }
    return trimmed;
  }
}
