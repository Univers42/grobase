import { Body, Controller, Get, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, UserContext } from '@mini-baas/common';
import { QueryService } from './query.service';
import { ExecuteQueryDto } from './dto/query.dto';

@ApiTags('query')
@Controller('query')
@UseGuards(AuthGuard)
export class QueryController {
  constructor(private readonly service: QueryService) {}

  @Post(':dbId/tables/:table')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiParam({ name: 'table', description: 'Table or collection name' })
  @ApiOperation({ summary: 'Execute a query on a registered database' })
  async execute(
    @CurrentUser() user: UserContext,
    @Param('dbId', ParseUUIDPipe) dbId: string,
    @Param('table') table: string,
    @Body() dto: ExecuteQueryDto,
  ) {
    return this.service.executeQuery(dbId, table, user.id, user.role, dto);
  }

  @Get(':dbId/tables')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'List tables/collections in a registered database' })
  async listTables(
    @CurrentUser() user: UserContext,
    @Param('dbId', ParseUUIDPipe) dbId: string,
  ) {
    return this.service.listTables(dbId, user.id, user.role);
  }
}
