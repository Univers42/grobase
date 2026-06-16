import { Body, Controller, Post, Req, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import {
  AuthGuard,
  CurrentIdentity,
  CurrentUser,
  UserContext,
  VerifiedRequestIdentity,
} from '@mini-baas/common';
import type { Request } from 'express';
import { GraphOverviewDto, GraphRequestDto } from './graph.dto';
import { GraphService } from './graph.service';
import { GraphResponse } from './graph.types';

// Root-mounted like QueryController: Kong strips `/query/v1`, so this serves at
// `/query/v1/graph`.
@ApiTags('graph')
@Controller('graph')
@UseGuards(AuthGuard)
export class GraphController {
  constructor(private readonly service: GraphService) {}

  @Post()
  @ApiOperation({
    summary: 'Assemble a node-link subgraph around a focus node (Obsidian-style local graph)',
  })
  async graph(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Body() dto: GraphRequestDto,
    @Req() request: Request,
  ): Promise<GraphResponse> {
    return this.service.deriveGraph(dto, user.id, {
      requestId: request.requestId,
      identity,
    });
  }

  @Post('overview')
  @ApiOperation({
    summary: 'Assemble the global (focus-less) graph from a set of resources (Obsidian vault view)',
  })
  async overview(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Body() dto: GraphOverviewDto,
    @Req() request: Request,
  ): Promise<GraphResponse> {
    return this.service.overview(dto, user.id, {
      requestId: request.requestId,
      identity,
    });
  }
}
