import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import type { AdapterOp } from '@mini-baas/database';
import { IsObject, IsOptional, IsString, IsUUID, MinLength } from 'class-validator';
import { ADAPTER_OPS } from './query.dto';

/** Legacy verbs that mean "insert" — the only ones an array of `values` can carry. */
const INSERT_VERBS: readonly string[] = ['insert', 'insertOne'];

/**
 * Body of `POST /query/v1/execute` — the `QueryRequest` schema of the public
 * OpenAPI spec (operation `queryExecute`), which every SDK sends.
 */
export class QueryRequestDto {
  @ApiProperty({ format: 'uuid', description: 'The mount (registered database) id.' })
  @IsUUID()
  database_id!: string;

  @ApiProperty({
    description:
      'A canonical op (list, get, insert, update, delete, upsert, aggregate, batch) or a legacy verb (select, find, insertOne, …).',
    example: 'list',
  })
  @IsString()
  action!: string;

  @ApiProperty({ description: 'Table or collection name.' })
  @IsString()
  @MinLength(1)
  resource!: string;

  @ApiPropertyOptional({
    type: 'object',
    additionalProperties: true,
    description:
      'The ExecuteQueryDto fields (data, filter, sort, limit, …); `values` is an alias of `data`.',
  })
  @IsOptional()
  @IsObject()
  payload?: Record<string, unknown>;
}

/** isAdapterOp reports whether `action` is a canonical operation rather than a legacy verb. */
function isAdapterOp(action: string): action is AdapterOp {
  return (ADAPTER_OPS as readonly string[]).includes(action);
}

/**
 * toExecuteQueryBody maps an execute request onto the plain body that the
 * `/:dbId/tables/:table` route validates as ExecuteQueryDto, so both routes share
 * one validation and one execution path. A canonical action becomes `op`; any
 * other stays `action`, where the DTO's legacy map applies or validation rejects
 * it. `values` (the SDK's builder) is an alias of `data`, and an array of values
 * on an insert becomes a `batch` of inserts. A `values` that cannot be mapped
 * (beside `data`, or an array on a non-insert) is left in the body, so the
 * pipe's forbidNonWhitelisted refuses it instead of guessing.
 * @param request the validated execute request
 * @returns the body to validate as ExecuteQueryDto
 */
export function toExecuteQueryBody(request: QueryRequestDto): Record<string, unknown> {
  const payload = request.payload ?? {};
  const verb = isAdapterOp(request.action) ? { op: request.action } : { action: request.action };
  const { values, ...rest } = payload;
  if (values === undefined || 'data' in rest) return { ...payload, ...verb };
  if (!Array.isArray(values)) return { ...rest, ...verb, data: values };
  if (!INSERT_VERBS.includes(request.action)) return { ...payload, ...verb };
  return {
    ...rest,
    op: 'batch',
    operations: values.map((data: unknown) => ({ op: 'insert', data })),
  };
}
