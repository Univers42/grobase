import { PipeTransform, Injectable, BadRequestException } from '@nestjs/common';

export interface PaginationParams {
  page: number;
  limit: number;
  skip: number;
}

@Injectable()
export class ParsePaginationPipe implements PipeTransform {
  private readonly defaultPage = 1;
  private readonly defaultLimit = 20;
  private readonly maxLimit = 100;

  transform(value: Record<string, string>): PaginationParams {
    const page = this.parsePositiveInt(value?.page, this.defaultPage);
    const limit = Math.min(
      this.parsePositiveInt(value?.limit, this.defaultLimit),
      this.maxLimit,
    );
    const skip = (page - 1) * limit;

    return { page, limit, skip };
  }

  private parsePositiveInt(value: string | undefined, defaultValue: number): number {
    if (!value) return defaultValue;
    const parsed = parseInt(value, 10);
    if (isNaN(parsed) || parsed < 1) {
      throw new BadRequestException(
        `"${value}" is not a valid positive integer`,
      );
    }
    return parsed;
  }
}
