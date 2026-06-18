/**
 * Allergen Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateAllergenDto, UpdateAllergenDto } from './dto/allergen.dto';

@Injectable()
export class AllergenService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll() {
    return this.prisma.allergen.findMany({ orderBy: { name: 'asc' } });
  }

  async findById(id: number) {
    const allergen = await this.prisma.allergen.findUnique({ where: { id } });
    if (!allergen) throw new NotFoundException('Allergen not found');
    return allergen;
  }

  async create(dto: CreateAllergenDto) {
    return this.prisma.allergen.create({
      data: { name: dto.name, icon_url: dto.iconUrl },
    });
  }

  async update(id: number, dto: UpdateAllergenDto) {
    await this.ensureExists(id);
    return this.prisma.allergen.update({
      where: { id },
      data: { name: dto.name, icon_url: dto.iconUrl },
    });
  }

  async delete(id: number) {
    await this.ensureExists(id);
    await this.prisma.allergen.delete({ where: { id } });
    return { message: 'Allergen deleted successfully' };
  }

  private async ensureExists(id: number) {
    const exists = await this.prisma.allergen.findUnique({ where: { id } });
    if (!exists) throw new NotFoundException('Allergen not found');
  }
}
