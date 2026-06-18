/**
 * Admin Service
 */
import {
  Injectable,
  NotFoundException,
  ConflictException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateEmployeeDto } from './dto/admin.dto';
import * as bcrypt from 'bcrypt';

@Injectable()
export class AdminService {
  constructor(private readonly prisma: PrismaService) {}

  async getAllUsers() {
    return this.prisma.user.findMany({
      where: { is_deleted: false },
      select: {
        id: true,
        email: true,
        first_name: true,
        last_name: true,
        is_active: true,
        created_at: true,
        Role: true,
      },
      orderBy: { created_at: 'desc' },
    });
  }

  async createEmployee(dto: CreateEmployeeDto) {
    const existing = await this.prisma.user.findUnique({
      where: { email: dto.email },
    });
    if (existing) throw new ConflictException('Email already registered');

    const hashedPassword = await bcrypt.hash(dto.password, 12);
    return this.prisma.user.create({
      data: {
        email: dto.email,
        password: hashedPassword,
        first_name: dto.firstName,
        last_name: dto.lastName,
        role_id: dto.roleId,
        is_email_verified: true,
      },
      include: { Role: true },
    });
  }

  async updateUserRole(userId: number, roleId: number) {
    await this.ensureUserExists(userId);
    await this.ensureRoleExists(roleId);
    return this.prisma.user.update({
      where: { id: userId },
      data: { role_id: roleId },
      include: { Role: true },
    });
  }

  async toggleUserActive(userId: number) {
    const user = await this.ensureUserExists(userId);
    return this.prisma.user.update({
      where: { id: userId },
      data: { is_active: !user.is_active },
    });
  }

  async getRoles() {
    return this.prisma.role.findMany({ orderBy: { id: 'asc' } });
  }

  private async ensureUserExists(id: number) {
    const user = await this.prisma.user.findUnique({ where: { id } });
    if (!user) throw new NotFoundException('User not found');
    return user;
  }

  private async ensureRoleExists(id: number) {
    const role = await this.prisma.role.findUnique({ where: { id } });
    if (!role) throw new NotFoundException('Role not found');
  }
}
