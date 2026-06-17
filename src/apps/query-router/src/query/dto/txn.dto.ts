import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsEnum,
  IsObject,
  IsOptional,
  IsString,
  ValidateNested,
} from 'class-validator';
import type { AdapterOp } from '@mini-baas/database';

/** Write ops permitted inside a transaction. Reads aren't offered yet — a txn is
 *  for atomic mutation (the osionos inspector writing a node + its edges). */
export const TXN_OPS = ['insert', 'update', 'delete', 'upsert'] as const;

/** One operation in a transactional batch (same fields as a single write). */
export class TxnOpDto {
  @ApiProperty({ enum: TXN_OPS, description: 'Write operation' })
  @IsEnum(TXN_OPS)
  op!: AdapterOp;

  @ApiProperty({ description: 'Target resource (table/collection) on the mount' })
  @IsString()
  resource!: string;

  @ApiPropertyOptional({ description: 'Row data for insert / update / upsert' })
  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'WHERE / filter for update / delete' })
  @IsOptional()
  @IsObject()
  filter?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'Idempotency key forwarded to the engine' })
  @IsOptional()
  @IsString()
  idempotencyKey?: string;
}

/**
 * Request body for `POST /query/v1/txn` — a **single-mount** atomic batch. Every
 * op runs in one backend transaction on `mount` and commits all-or-nothing
 * (rolled back on the first failure). The engine must be transactional
 * (postgresql/mysql); other engines are rejected. Cross-mount atomicity is a
 * different (2PC) problem and is not offered here.
 */
export class TxnRequestDto {
  @ApiProperty({ description: 'Mount id (dbId); all operations run in one transaction on it' })
  @IsString()
  mount!: string;

  @ApiProperty({
    type: [TxnOpDto],
    description: '1–50 write ops applied atomically (all-or-nothing)',
  })
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(50)
  @ValidateNested({ each: true })
  @Type(() => TxnOpDto)
  operations!: TxnOpDto[];
}
