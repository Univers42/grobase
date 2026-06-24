import { ParsePaginationPipe } from '../parse-pagination.pipe';
import { BadRequestException } from '@nestjs/common';

describe('ParsePaginationPipe', () => {
  let pipe: ParsePaginationPipe;

  beforeEach(() => {
    pipe = new ParsePaginationPipe();
  });

  it('should return defaults when no params provided', () => {
    const result = pipe.transform({});
    expect(result).toEqual({ page: 1, limit: 20, skip: 0 });
  });

  it('should parse valid page and limit', () => {
    const result = pipe.transform({ page: '2', limit: '10' });
    expect(result).toEqual({ page: 2, limit: 10, skip: 10 });
  });

  it('should calculate skip offset correctly', () => {
    const result = pipe.transform({ page: '3', limit: '15' });
    expect(result.skip).toBe(30);
  });

  it('should cap limit at 100', () => {
    const result = pipe.transform({ page: '1', limit: '200' });
    expect(result.limit).toBe(100);
  });

  it('should reject negative page numbers', () => {
    expect(() => pipe.transform({ page: '-1' })).toThrow(BadRequestException);
  });

  it('should reject non-numeric page values', () => {
    expect(() => pipe.transform({ page: 'abc' })).toThrow(BadRequestException);
  });

  it('should reject zero as page number', () => {
    expect(() => pipe.transform({ page: '0' })).toThrow(BadRequestException);
  });
});
