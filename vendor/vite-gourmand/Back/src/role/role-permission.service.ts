/**
 * Role-Permission Service - Manage role-permission assignments
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { RolePermission, Permission } from '../../generated/prisma/client.js';

interface RolePermissionWithPermission extends RolePermission {
  Permission: Permission;
}

@Injectable()
export class RolePermissionService {
  constructor(private readonly prisma: PrismaService) {}

  /** Assign permissions to role */
  async assignPermissions(roleId: number, permissionIds: number[]) {
    await this.validateRoleExists(roleId);

    const existing = await this.prisma.rolePermission.findMany({
      where: { role_id: roleId },
      select: { permission_id: true },
    });

    const existingIds = new Set(
      existing.map((p: { permission_id: number }) => p.permission_id),
    );
    const newIds = permissionIds.filter((id) => !existingIds.has(id));

    if (newIds.length > 0) {
      await this.prisma.rolePermission.createMany({
        data: newIds.map((permissionId) => ({
          role_id: roleId,
          permission_id: permissionId,
        })),
      });
    }
    return this.getRoleWithPermissions(roleId);
  }

  /** Remove permissions from role */
  async removePermissions(roleId: number, permissionIds: number[]) {
    await this.validateRoleExists(roleId);
    await this.prisma.rolePermission.deleteMany({
      where: { role_id: roleId, permission_id: { in: permissionIds } },
    });
    return this.getRoleWithPermissions(roleId);
  }

  /** Check if user has a specific permission */
  async userHasPermission(
    userId: number,
    permissionName: string,
  ): Promise<boolean> {
    const user = await this.getUserWithPermissions(userId);
    if (!user?.Role) return false;
    return user.Role.RolePermission.some(
      (rp: RolePermissionWithPermission) =>
        rp.Permission.name === permissionName,
    );
  }

  /** Get all permissions for a user */
  async getUserPermissions(userId: number) {
    const user = await this.getUserWithPermissions(userId);
    if (!user?.Role) return [];
    return user.Role.RolePermission.map(
      (rp: RolePermissionWithPermission) => rp.Permission,
    );
  }

  private async validateRoleExists(roleId: number) {
    const role = await this.prisma.role.findUnique({ where: { id: roleId } });
    if (!role) throw new NotFoundException('Role not found');
  }

  private async getRoleWithPermissions(roleId: number) {
    return this.prisma.role.findUnique({
      where: { id: roleId },
      include: { RolePermission: { include: { Permission: true } } },
    });
  }

  private async getUserWithPermissions(userId: number) {
    return this.prisma.user.findUnique({
      where: { id: userId },
      include: {
        Role: {
          include: { RolePermission: { include: { Permission: true } } },
        },
      },
    });
  }
}
