/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   policies.controller.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import { AuthGuard, Roles, RolesGuard } from '@mini-baas/common';
import { PoliciesService } from './policies.service';
import { CreatePolicyDto } from './dto/policy.dto';

@ApiTags('policies')
@Controller('policies')
@UseGuards(AuthGuard, RolesGuard)
@Roles('admin', 'service_role')
export class PoliciesController {
  constructor(private readonly service: PoliciesService) {}

  @Get()
  @ApiOperation({ summary: 'List all resource policies' })
  async list() {
    return this.service.list();
  }

  @Get('role/:roleId')
  @ApiParam({ name: 'roleId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'List policies for a specific role' })
  async byRole(@Param('roleId', ParseUUIDPipe) roleId: string) {
    return this.service.findByRole(roleId);
  }

  @Post()
  @ApiOperation({ summary: 'Create a new resource policy' })
  async create(@Body() dto: CreatePolicyDto) {
    return this.service.create(dto);
  }

  @Delete(':id')
  @ApiParam({ name: 'id', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'Delete a resource policy' })
  async remove(@Param('id', ParseUUIDPipe) id: string) {
    return this.service.remove(id);
  }
}
