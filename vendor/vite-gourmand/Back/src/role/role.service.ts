/**
 * Role Service - Manage user roles (CRUD only)
 */
import {
  Injectable,
  NotFoundException,
  ConflictException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateRoleDto, UpdateRoleDto } from './dto/role.dto';

@Injectable()
export class RoleService {
  constructor(private readonly prisma: PrismaService) {}

  /** Get all roles with permissions count */
  async findAll() {
    return this.prisma.role.findMany({
      include: {
        RolePermission: { include: { Permission: true } },
        _count: { select: { User: true } },
      },
      orderBy: { name: 'asc' },
    });
  }

  /** Get role by ID */
  async findById(id: number) {
    const role = await this.prisma.role.findUnique({
      where: { id },
      include: {
        RolePermission: { include: { Permission: true } },
        User: {
          select: { id: true, email: true, first_name: true, last_name: true },
        },
      },
    });
    if (!role) throw new NotFoundException('Role not found');
    return role;
  }

  /** Get role by name */
  async findByName(name: string) {
    return this.prisma.role.findUnique({
      where: { name },
      include: { RolePermission: { include: { Permission: true } } },
    });
  }

  /** Create role */
  async create(dto: CreateRoleDto) {
    await this.checkDuplicate(dto.name);
    const role = await this.prisma.role.create({
      data: { name: dto.name, description: dto.description },
    });
    if (dto.permissionIds?.length)
      await this.linkPermissions(role.id, dto.permissionIds);
    return this.findById(role.id);
  }

  /** Update role */
  async update(id: number, dto: UpdateRoleDto) {
    const role = await this.findById(id);
    if (dto.name && dto.name !== role.name) await this.checkDuplicate(dto.name);
    await this.prisma.role.update({
      where: { id },
      data: { name: dto.name, description: dto.description },
    });
    if (dto.permissionIds) await this.replacePermissions(id, dto.permissionIds);
    return this.findById(id);
  }

  /** Delete role */
  async delete(id: number) {
    const role = await this.prisma.role.findUnique({
      where: { id },
      include: { _count: { select: { User: true } } },
    });
    if (!role) throw new NotFoundException('Role not found');
    if (role._count.User > 0)
      throw new ConflictException('Cannot delete role with assigned users');
    await this.prisma.rolePermission.deleteMany({ where: { role_id: id } });
    return this.prisma.role.delete({ where: { id } });
  }

  private async checkDuplicate(name: string) {
    const exists = await this.prisma.role.findUnique({ where: { name } });
    if (exists) throw new ConflictException('Role name already exists');
  }

  private async linkPermissions(roleId: number, permissionIds: number[]) {
    await this.prisma.rolePermission.createMany({
      data: permissionIds.map((pid) => ({
        role_id: roleId,
        permission_id: pid,
      })),
    });
  }

  private async replacePermissions(roleId: number, permissionIds: number[]) {
    await this.prisma.rolePermission.deleteMany({ where: { role_id: roleId } });
    if (permissionIds.length > 0)
      await this.linkPermissions(roleId, permissionIds);
  }
}
