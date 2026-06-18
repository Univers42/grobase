/**
 * Role Module
 */
import { Module } from '@nestjs/common';
import { RoleController } from './role.controller';
import { RoleService } from './role.service';
import { PermissionService } from './permission.service';
import { RolePermissionService } from './role-permission.service';
import { PrismaModule } from '../prisma';

@Module({
  imports: [PrismaModule],
  controllers: [RoleController],
  providers: [RoleService, PermissionService, RolePermissionService],
  exports: [RoleService, PermissionService, RolePermissionService],
})
export class RoleModule {}
