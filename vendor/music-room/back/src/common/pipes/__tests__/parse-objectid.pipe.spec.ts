import { ParseObjectIdPipe } from '../parse-objectid.pipe';
import { BadRequestException } from '@nestjs/common';

describe('ParseObjectIdPipe', () => {
  let pipe: ParseObjectIdPipe;

  beforeEach(() => {
    pipe = new ParseObjectIdPipe();
  });

  it('should accept valid ObjectId strings', () => {
    const validId = '507f1f77bcf86cd799439011';
    const result = pipe.transform(validId);
    expect(result.toString()).toBe(validId);
  });

  it('should reject invalid ObjectId strings', () => {
    expect(() => pipe.transform('invalid')).toThrow(BadRequestException);
  });

  it('should reject empty strings', () => {
    expect(() => pipe.transform('')).toThrow(BadRequestException);
  });

  it('should reject short hex strings', () => {
    expect(() => pipe.transform('507f1f77')).toThrow(BadRequestException);
  });

  it('should include the invalid value in error message', () => {
    try {
      pipe.transform('bad-id');
    } catch (e) {
      expect((e as BadRequestException).message).toContain('bad-id');
    }
  });
});
