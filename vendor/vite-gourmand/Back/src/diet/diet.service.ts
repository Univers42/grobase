/**
 * Diet Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateDietDto, UpdateDietDto } from './dto/diet.dto';

@Injectable()
export class DietService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll() {
    return this.prisma.diet.findMany({ orderBy: { name: 'asc' } });
  }

  async findById(id: number) {
    const diet = await this.prisma.diet.findUnique({ where: { id } });
    if (!diet) throw new NotFoundException('Diet not found');
    return diet;
  }

  async create(dto: CreateDietDto) {
    return this.prisma.diet.create({
      data: {
        name: dto.name,
        description: dto.description,
        icon_url: dto.iconUrl,
      },
    });
  }

  async update(id: number, dto: UpdateDietDto) {
    await this.ensureExists(id);
    return this.prisma.diet.update({
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
    await this.prisma.diet.delete({ where: { id } });
    return { message: 'Diet deleted successfully' };
  }

  private async ensureExists(id: number) {
    const exists = await this.prisma.diet.findUnique({ where: { id } });
    if (!exists) throw new NotFoundException('Diet not found');
  }
}
