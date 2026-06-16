/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   prompts.controller.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, Roles, RolesGuard } from '@mini-baas/common';
import { PromptsService } from './prompts.service';
import { CreatePromptDto } from '../dto/ai.dto';

@ApiTags('prompts')
@Controller('admin/prompts')
@UseGuards(AuthGuard, RolesGuard)
@Roles('service_role')
@ApiBearerAuth()
@ApiSecurity('apikey')
export class PromptsController {
  constructor(private readonly service: PromptsService) {}

  @Get()
  @ApiOperation({ summary: 'List all prompt templates (admin)' })
  async list() {
    return this.service.list();
  }

  @Get(':mode')
  @ApiOperation({ summary: 'Get a prompt template by mode (admin)' })
  async get(@Param('mode') mode: string) {
    return this.service.get(mode);
  }

  @Post()
  @ApiOperation({ summary: 'Create a new prompt template (admin)' })
  async create(@Body() dto: CreatePromptDto) {
    return this.service.create(dto.mode, dto.template, dto.description);
  }

  @Put(':mode')
  @ApiOperation({ summary: 'Update a prompt template (admin)' })
  async update(
    @Param('mode') mode: string,
    @Body() dto: CreatePromptDto,
  ) {
    return this.service.update(mode, dto.template, dto.description);
  }

  @Delete(':mode')
  @ApiOperation({ summary: 'Delete a prompt template (admin)' })
  async remove(@Param('mode') mode: string) {
    return this.service.remove(mode);
  }
}
