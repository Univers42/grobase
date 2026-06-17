/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   permissions.controller.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, Roles, RolesGuard, UserContext } from '@mini-baas/common';
import { PermissionsService } from './permissions.service';
import { AssignRoleDto, CheckPermissionDto } from './dto/permission.dto';

@ApiTags('permissions')
@Controller('permissions')
@UseGuards(AuthGuard)
export class PermissionsController {
  constructor(private readonly service: PermissionsService) {}

  @Post('check')
  @ApiOperation({ summary: 'Check if the current user has a specific permission' })
  async check(@CurrentUser() user: UserContext, @Body() dto: CheckPermissionDto) {
    return this.service.check(user.id, dto.resource_type, dto.resource_name, dto.action);
  }

  @Get('roles')
  @ApiOperation({ summary: 'Get roles assigned to the current user' })
  async myRoles(@CurrentUser() user: UserContext) {
    const roles = await this.service.getUserRoles(user.id);
    return { user_id: user.id, roles };
  }

  @Get('roles/:userId')
  @UseGuards(RolesGuard)
  @Roles('admin', 'service_role')
  @ApiParam({ name: 'userId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'Get roles of any user (admin only)' })
  async userRoles(@Param('userId') userId: string) {
    const roles = await this.service.getUserRoles(userId);
    return { user_id: userId, roles };
  }

  @Post('roles/assign')
  @UseGuards(RolesGuard)
  @Roles('admin', 'service_role')
  @ApiOperation({ summary: 'Assign a role to a user (admin only)' })
  async assign(@CurrentUser() user: UserContext, @Body() dto: AssignRoleDto) {
    return this.service.assignRole(dto.target_user_id, dto.role_name, user.id);
  }

  @Delete('roles/:userId/:roleName')
  @UseGuards(RolesGuard)
  @Roles('admin', 'service_role')
  @ApiParam({ name: 'userId', type: 'string', format: 'uuid' })
  @ApiParam({ name: 'roleName' })
  @ApiOperation({ summary: 'Revoke a role from a user (admin only)' })
  async revoke(
    @Param('userId') userId: string,
    @Param('roleName') roleName: string,
  ) {
    return this.service.revokeRole(userId, roleName);
  }
}
