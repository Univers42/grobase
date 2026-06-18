/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   admin.controller.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import { AuthGuard, Roles, RolesGuard } from '@mini-baas/common';
import { AdminService } from './admin.service';
import { CreateIndexDto, UpdateSchemaDto } from './dto/admin.dto';

@ApiTags('admin')
@Controller('admin')
@UseGuards(AuthGuard)
export class AdminController {
  constructor(private readonly service: AdminService) {}

  @Get('collections')
  @ApiOperation({ summary: 'List all MongoDB collections' })
  async listCollections() {
    return this.service.listCollections();
  }

  @Get('schemas/:name')
  @ApiParam({ name: 'name' })
  @ApiOperation({ summary: 'Get collection schema/validator info' })
  async getSchema(@Param('name') name: string) {
    return this.service.getSchema(name);
  }

  @Put('schemas/:name')
  @UseGuards(RolesGuard)
  @Roles('service_role')
  @ApiParam({ name: 'name' })
  @ApiOperation({ summary: 'Create or update collection validator (service_role only)' })
  async updateSchema(@Param('name') name: string, @Body() dto: UpdateSchemaDto) {
    return this.service.updateSchema(name, dto);
  }

  @Delete('schemas/:name')
  @UseGuards(RolesGuard)
  @Roles('service_role')
  @ApiParam({ name: 'name' })
  @ApiOperation({ summary: 'Drop entire collection (service_role only)' })
  async dropCollection(@Param('name') name: string) {
    return this.service.dropCollection(name);
  }

  @Post('indexes/:name')
  @UseGuards(RolesGuard)
  @Roles('service_role')
  @ApiParam({ name: 'name' })
  @ApiOperation({ summary: 'Create index on collection (service_role only)' })
  async createIndex(@Param('name') name: string, @Body() dto: CreateIndexDto) {
    return this.service.createIndex(name, dto);
  }
}
