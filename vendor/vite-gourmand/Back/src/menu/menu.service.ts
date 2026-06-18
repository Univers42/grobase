/**
 * Menu Service
 * Core menu management logic
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateMenuDto, UpdateMenuDto, MenuFilterDto } from './dto/menu.dto';
import { buildPaginationMeta } from '../common';

@Injectable()
export class MenuService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(filters: MenuFilterDto) {
    const { page = 1, limit = 20 } = filters;
    const skip = (page - 1) * limit;
    const where = this.buildWhereClause(filters);

    const [menus, total] = await Promise.all([
      this.prisma.menu.findMany({
        where,
        skip,
        take: limit,
        orderBy: { created_at: 'desc' },
        include: this.getMenuIncludes(),
      }),
      this.prisma.menu.count({ where }),
    ]);

    return { items: menus, meta: buildPaginationMeta(page, limit, total) };
  }

  async findById(id: number) {
    const menu = await this.prisma.menu.findUnique({
      where: { id },
      include: this.getMenuIncludes(),
    });
    if (!menu) throw new NotFoundException('Menu not found');
    return menu;
  }

  async create(dto: CreateMenuDto, createdBy: number) {
    return this.prisma.menu.create({
      data: {
        title: dto.title,
        description: dto.description,
        person_min: dto.personMin,
        price_per_person: dto.pricePerPerson,
        remaining_qty: dto.remainingQty ?? 0,
        diet_id: dto.dietId,
        theme_id: dto.themeId,
        created_by: createdBy,
        is_seasonal: dto.isSeasonal ?? false,
        available_from: dto.availableFrom,
        available_until: dto.availableUntil,
      },
      include: this.getMenuIncludes(),
    });
  }

  async update(id: number, dto: UpdateMenuDto) {
    await this.ensureExists(id);
    return this.prisma.menu.update({
      where: { id },
      data: {
        title: dto.title,
        description: dto.description,
        person_min: dto.personMin,
        price_per_person: dto.pricePerPerson,
        remaining_qty: dto.remainingQty,
        diet_id: dto.dietId,
        theme_id: dto.themeId,
      },
      include: this.getMenuIncludes(),
    });
  }

  async delete(id: number) {
    await this.ensureExists(id);
    await this.prisma.menu.delete({ where: { id } });
    return { message: 'Menu deleted successfully' };
  }

  async publish(id: number) {
    return this.updateStatus(id, 'published');
  }

  async unpublish(id: number) {
    return this.updateStatus(id, 'draft');
  }

  private async updateStatus(id: number, status: string) {
    await this.ensureExists(id);
    return this.prisma.menu.update({
      where: { id },
      data: {
        status,
        published_at: status === 'published' ? new Date() : null,
      },
    });
  }

  private async ensureExists(id: number) {
    const exists = await this.prisma.menu.findUnique({ where: { id } });
    if (!exists) throw new NotFoundException('Menu not found');
  }

  private buildWhereClause(filters: MenuFilterDto) {
    return {
      ...(filters.status
        ? { status: filters.status }
        : { status: 'published' }),
      ...(filters.dietId && { diet_id: filters.dietId }),
      ...(filters.themeId && { theme_id: filters.themeId }),
    };
  }

  private getMenuIncludes() {
    return {
      Diet: true,
      Theme: true,
      MenuImage: true,
      Dish: {
        include: {
          DishAllergen: {
            include: {
              Allergen: true,
            },
          },
        },
      },
    };
  }
}
