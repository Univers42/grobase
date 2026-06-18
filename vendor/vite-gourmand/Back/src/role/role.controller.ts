/**
 * Role & Permission Controller
 */
import {
  Controller,
  Get,
  Post,
  Put,
  Delete,
  Body,
  Param,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { RoleService } from './role.service';
import { PermissionService } from './permission.service';
import { RolePermissionService } from './role-permission.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import {
  CreatePermissionDto,
  UpdatePermissionDto,
  CreateRoleDto,
  UpdateRoleDto,
  AssignPermissionsDto,
} from './dto/role.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('roles')
@Controller('roles')
@ApiBearerAuth()
export class RoleController {
  constructor(
    private readonly roleService: RoleService,
    private readonly permissionService: PermissionService,
    private readonly rolePermissionService: RolePermissionService,
  ) {}

  // ============ Permission Endpoints ============

  @Get('permissions')
  @Roles('admin')
  @ApiOperation({ summary: 'List all permissions' })
  async findAllPermissions() {
    return this.permissionService.findAll();
  }

  @Get('permissions/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Get permission by ID' })
  async findPermissionById(@Param('id', SafeParseIntPipe) id: number) {
    return this.permissionService.findById(id);
  }

  @Post('permissions')
  @Roles('admin')
  @ApiOperation({ summary: 'Create permission' })
  async createPermission(@Body() dto: CreatePermissionDto) {
    return this.permissionService.create(dto);
  }

  @Put('permissions/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Update permission' })
  async updatePermission(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdatePermissionDto,
  ) {
    return this.permissionService.update(id, dto);
  }

  @Delete('permissions/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete permission' })
  async deletePermission(@Param('id', SafeParseIntPipe) id: number) {
    return this.permissionService.delete(id);
  }

  // ============ Role Endpoints ============

  @Get()
  @Roles('admin')
  @ApiOperation({ summary: 'List all roles' })
  async findAllRoles() {
    return this.roleService.findAll();
  }

  @Get(':id')
  @Roles('admin')
  @ApiOperation({ summary: 'Get role by ID' })
  async findRoleById(@Param('id', SafeParseIntPipe) id: number) {
    return this.roleService.findById(id);
  }

  @Post()
  @Roles('admin')
  @ApiOperation({ summary: 'Create role' })
  async createRole(@Body() dto: CreateRoleDto) {
    return this.roleService.create(dto);
  }

  @Put(':id')
  @Roles('admin')
  @ApiOperation({ summary: 'Update role' })
  async updateRole(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateRoleDto,
  ) {
    return this.roleService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete role' })
  async deleteRole(@Param('id', SafeParseIntPipe) id: number) {
    return this.roleService.delete(id);
  }

  // ============ Role Permission Management ============

  @Post(':id/permissions')
  @Roles('admin')
  @ApiOperation({ summary: 'Assign permissions to role' })
  async assignPermissions(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: AssignPermissionsDto,
  ) {
    return this.rolePermissionService.assignPermissions(id, dto.permissionIds);
  }

  @Delete(':id/permissions')
  @Roles('admin')
  @ApiOperation({ summary: 'Remove permissions from role' })
  async removePermissions(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: AssignPermissionsDto,
  ) {
    return this.rolePermissionService.removePermissions(id, dto.permissionIds);
  }

  // ============ User Permission Check ============

  @Get('users/:userId/permissions')
  @Roles('admin')
  @ApiOperation({ summary: 'Get user permissions' })
  async getUserPermissions(@Param('userId', SafeParseIntPipe) userId: number) {
    return this.rolePermissionService.getUserPermissions(userId);
  }

  @Get('users/:userId/check/:permissionName')
  @Roles('admin')
  @ApiOperation({ summary: 'Check if user has permission' })
  async userHasPermission(
    @Param('userId', SafeParseIntPipe) userId: number,
    @Param('permissionName') permissionName: string,
  ) {
    const hasPermission = await this.rolePermissionService.userHasPermission(
      userId,
      permissionName,
    );
    return { hasPermission };
  }

  // ============ Current User Permissions ============

  @Get('me/permissions')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Get my permissions' })
  async getMyPermissions(@CurrentUser() user: JwtPayload) {
    return this.rolePermissionService.getUserPermissions(user.sub);
  }
}
