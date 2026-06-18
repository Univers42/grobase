/**
 * Permission Service - CRUD operations for permissions
 */
import {
  Injectable,
  NotFoundException,
  ConflictException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreatePermissionDto, UpdatePermissionDto } from './dto/role.dto';

@Injectable()
export class PermissionService {
  constructor(private readonly prisma: PrismaService) {}

  /** Get all permissions */
  async findAll() {
    return this.prisma.permission.findMany({ orderBy: { name: 'asc' } });
  }

  /** Get permission by ID with roles */
  async findById(id: number) {
    const permission = await this.prisma.permission.findUnique({
      where: { id },
      include: { RolePermission: { include: { Role: true } } },
    });
    if (!permission) throw new NotFoundException('Permission not found');
    return permission;
  }

  /** Get permission by name */
  async findByName(name: string) {
    return this.prisma.permission.findUnique({ where: { name } });
  }

  /** Create permission */
  async create(dto: CreatePermissionDto) {
    const existing = await this.findByName(dto.name);
    if (existing) {
      throw new ConflictException('Permission with this name already exists');
    }
    return this.prisma.permission.create({
      data: {
        name: dto.name,
        resource: dto.resource ?? '',
        action: dto.action ?? '',
      },
    });
  }

  /** Update permission */
  async update(id: number, dto: UpdatePermissionDto) {
    const permission = await this.prisma.permission.findUnique({
      where: { id },
    });
    if (!permission) throw new NotFoundException('Permission not found');

    if (dto.name && dto.name !== permission.name) {
      const existing = await this.findByName(dto.name);
      if (existing) {
        throw new ConflictException('Permission with this name already exists');
      }
    }
    return this.prisma.permission.update({ where: { id }, data: dto });
  }

  /** Delete permission */
  async delete(id: number) {
    const permission = await this.prisma.permission.findUnique({
      where: { id },
    });
    if (!permission) throw new NotFoundException('Permission not found');

    await this.prisma.rolePermission.deleteMany({
      where: { permission_id: id },
    });
    return this.prisma.permission.delete({ where: { id } });
  }
}
