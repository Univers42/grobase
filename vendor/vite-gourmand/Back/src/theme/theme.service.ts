/**
 * Theme Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateThemeDto, UpdateThemeDto } from './dto/theme.dto';

@Injectable()
export class ThemeService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll() {
    return this.prisma.theme.findMany({ orderBy: { name: 'asc' } });
  }

  async findById(id: number) {
    const theme = await this.prisma.theme.findUnique({ where: { id } });
    if (!theme) throw new NotFoundException('Theme not found');
    return theme;
  }

  async create(dto: CreateThemeDto) {
    return this.prisma.theme.create({
      data: {
        name: dto.name,
        description: dto.description,
        icon_url: dto.iconUrl,
      },
    });
  }

  async update(id: number, dto: UpdateThemeDto) {
    await this.ensureExists(id);
    return this.prisma.theme.update({
      where: { id },
      data: {
        name: dto.name,
        description: dto.description,
        icon_url: dto.iconUrl,
      },
    });
  }

  async delete(id: number) {
    await this.ensureExists(id);
    await this.prisma.theme.delete({ where: { id } });
    return { message: 'Theme deleted successfully' };
  }

  private async ensureExists(id: number) {
    const exists = await this.prisma.theme.findUnique({ where: { id } });
    if (!exists) throw new NotFoundException('Theme not found');
  }
}
