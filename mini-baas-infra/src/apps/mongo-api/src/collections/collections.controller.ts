/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   collections.controller.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, UserContext } from '@mini-baas/common';
import { CollectionsService } from './collections.service';
import {
  CreateDocumentDto,
  ListDocumentsQueryDto,
  PatchDocumentDto,
} from './dto/collection.dto';

@ApiTags('collections')
@Controller('collections/:name/documents')
@UseGuards(AuthGuard)
export class CollectionsController {
  constructor(private readonly service: CollectionsService) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  @ApiParam({ name: 'name', description: 'Collection name (1-64 chars, alphanumeric/dash/underscore)' })
  @ApiOperation({ summary: 'Create a document (owner_id injected automatically)' })
  async create(
    @CurrentUser() user: UserContext,
    @Param('name') name: string,
    @Body() dto: CreateDocumentDto,
  ) {
    return this.service.create(name, user.id, dto.data);
  }

  @Get()
  @ApiParam({ name: 'name' })
  @ApiOperation({ summary: 'List documents (owner-isolated, paginated, filterable)' })
  async findAll(
    @CurrentUser() user: UserContext,
    @Param('name') name: string,
    @Query() query: ListDocumentsQueryDto,
  ) {
    return this.service.findAll(name, user.id, {
      limit: query.limit ?? 20,
      offset: query.offset ?? 0,
      sort: query.sort,
      filter: query.filter,
    });
  }

  @Get(':id')
  @ApiParam({ name: 'name' })
  @ApiParam({ name: 'id', description: 'Document ObjectId' })
  @ApiOperation({ summary: 'Get a single document by ID' })
  async findOne(
    @CurrentUser() user: UserContext,
    @Param('name') name: string,
    @Param('id') id: string,
  ) {
    return this.service.findOne(name, user.id, id);
  }

  @Patch(':id')
  @ApiParam({ name: 'name' })
  @ApiParam({ name: 'id' })
  @ApiOperation({ summary: 'Partial update via $set' })
  async patch(
    @CurrentUser() user: UserContext,
    @Param('name') name: string,
    @Param('id') id: string,
    @Body() dto: PatchDocumentDto,
  ) {
    return this.service.patch(name, user.id, id, dto.patch);
  }

  @Delete(':id')
  @ApiParam({ name: 'name' })
  @ApiParam({ name: 'id' })
  @ApiOperation({ summary: 'Delete a document by ID' })
  async remove(
    @CurrentUser() user: UserContext,
    @Param('name') name: string,
    @Param('id') id: string,
  ) {
    return this.service.remove(name, user.id, id);
  }
}
