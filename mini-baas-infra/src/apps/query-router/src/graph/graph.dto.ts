import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsArray, IsInt, IsObject, IsOptional, IsString, Max, Min } from 'class-validator';
import { EdgeGenerators, ResourceRef } from './graph.types';

/** Request body for `POST /query/v1/graph`. */
export class GraphRequestDto {
  @ApiProperty({ description: 'Focus node id `mount:resource:pk`', example: 'db-1:notes:42' })
  @IsString()
  focus!: string;

  @ApiPropertyOptional({ description: 'Neighbourhood radius (0–3)', default: 1 })
  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(3)
  depth?: number;

  @ApiProperty({ description: 'Mount id (dbId) holding the `edges` records' })
  @IsString()
  edgesDbId!: string;

  @ApiPropertyOptional({ description: 'Edge resource name', default: 'edges' })
  @IsOptional()
  @IsString()
  edgesTable?: string;

  @ApiPropertyOptional({
    description:
      'Secondary edge generators derived from node data: ' +
      '`{ noteField?, tags?: {field,mount,resource}, references?: [{field,mount,resource}] }`',
  })
  @IsOptional()
  @IsObject()
  generators?: EdgeGenerators;
}

/** Request body for `POST /query/v1/graph/overview` — the global (focus-less) graph. */
export class GraphOverviewDto {
  @ApiProperty({
    description: 'Node sources to load, each `{ dbId, table }` (one resource per mount)',
    example: [{ dbId: 'db-1', table: 'notes' }],
  })
  @IsArray()
  resources!: ResourceRef[];

  @ApiProperty({ description: 'Mount id (dbId) holding the `edges` records' })
  @IsString()
  edgesDbId!: string;

  @ApiPropertyOptional({ description: 'Edge resource name', default: 'edges' })
  @IsOptional()
  @IsString()
  edgesTable?: string;

  @ApiPropertyOptional({ description: 'Max rows loaded per resource (1–2000)', default: 500 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(2000)
  limit?: number;

  @ApiPropertyOptional({ description: 'Secondary edge generators (same shape as /graph)' })
  @IsOptional()
  @IsObject()
  generators?: EdgeGenerators;
}
