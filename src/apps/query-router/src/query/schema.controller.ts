/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.controller.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/09 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/09 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Get, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import {
  AuthGuard,
  CurrentIdentity,
  CurrentUser,
  UserContext,
  VerifiedRequestIdentity,
} from '@mini-baas/common';
import { SchemaService, SchemaDdlResponse, SchemaResponse } from './schema.service';
import { SchemaDdlRequestDto } from './dto/schema-ddl.dto';

// Root-mounted like QueryController: Kong strips `/query/v1` (strip_path), so
// this serves the public `GET /query/v1/:dbId/schema` as `GET /:dbId/schema`.
@ApiTags('query')
@Controller()
@UseGuards(AuthGuard)
export class SchemaController {
  constructor(private readonly service: SchemaService) {}

  @Get(':dbId/schema')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({
    summary: 'Describe the schema of a registered database (engine-agnostic)',
    description:
      'Returns the mount’s tables/collections with normalized column types ' +
      '(text|integer|float|decimal|boolean|date|datetime|json|uuid|enum|array|objectid|unknown), ' +
      'primary/foreign keys and enum values, plus the engine’s live capability descriptor. ' +
      'Mongo collections without a $jsonSchema validator are sample-inferred (`inferred: true`). ' +
      'Engines without an introspection surface (redis/http) return 422 unsupported_capability.',
  })
  async describe(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
  ): Promise<SchemaResponse> {
    return this.service.describe(dbId, user.id, identity);
  }

  @Post(':dbId/schema/ddl')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({
    summary: 'Apply ONE schema-DDL operation to a registered database (engine-agnostic)',
    description:
      'Single operation per request (add_column | drop_column | alter_column_type | ' +
      'create_table | drop_table) — deliberate, MySQL DDL is non-transactional. ' +
      'Destructive ops (drop_column, drop_table) require `"confirm": true`. ' +
      'For alter_column_type the FULL target definition is composed server-side: ' +
      'attributes omitted from `column` are preserved from the current column. ' +
      'When the existing data is incompatible with the requested type the engine ' +
      'rejects with 409 Conflict; engines without a DDL surface (redis/http) return ' +
      '422 unsupported_capability. On success the schema cache for this database is busted.',
  })
  async applyDdl(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
    @Body() dto: SchemaDdlRequestDto,
  ): Promise<SchemaDdlResponse> {
    return this.service.applyDdl(dbId, user.id, dto, identity);
  }
}
