// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { BadRequestException } from '@nestjs/common';
import { Type } from 'class-transformer';
import { IsIn, IsString, ValidateNested } from 'class-validator';
import { createValidationPipe } from './validation.pipe';

class Column {
  @IsIn(['text', 'integer'])
  normalized_type!: string;
}

class CreateTable {
  @IsString()
  table!: string;

  @ValidateNested({ each: true })
  @Type(() => Column)
  columns!: Column[];
}

async function messagesFor(body: unknown): Promise<string[]> {
  try {
    await createValidationPipe().transform(body, { type: 'body', metatype: CreateTable });
  } catch (err) {
    expect(err).toBeInstanceOf(BadRequestException);
    return ((err as BadRequestException).getResponse() as { message: string[] }).message;
  }
  throw new Error('expected a validation error');
}

describe('createValidationPipe', () => {
  it('names the nested field that failed instead of an empty list', async () => {
    const messages = await messagesFor({
      table: 't',
      columns: [{ normalized_type: 'text' }, { normalized_type: 'varchar' }],
    });
    expect(messages).toHaveLength(1);
    expect(messages[0]).toMatch(/^columns\.1\.normalized_type must be one of/);
  });

  it('keeps top-level messages unprefixed', async () => {
    expect(await messagesFor({ columns: [] })).toEqual(['table must be a string']);
  });
});
