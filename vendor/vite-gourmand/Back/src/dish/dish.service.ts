/**
 * Dish Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateDishDto, UpdateDishDto } from './dto/dish.dto';
import { PaginationDto, buildPaginationMeta } from '../common';

@Injectable()
export class DishService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(pagination: PaginationDto) {
    const { page = 1, limit = 20 } = pagination;
    const skip = (page - 1) * limit;

    const [dishes, total] = await Promise.all([
      this.prisma.dish.findMany({
        skip,
        take: limit,
        include: { Allergen: true },
      }),
      this.prisma.dish.count(),
    ]);

    return { items: dishes, meta: buildPaginationMeta(page, limit, total) };
  }

  async findById(id: number) {
    const dish = await this.prisma.dish.findUnique({
      where: { id },
      include: {
        Allergen: true,
        DishIngredient: { include: { Ingredient: true } },
      },
    });
    if (!dish) throw new NotFoundException('Dish not found');
    return dish;
  }

  async create(dto: CreateDishDto) {
    return this.prisma.dish.create({
      data: {
        title: dto.title,
        description: dto.description,
        photo_url: dto.photoUrl,
        course_type: dto.courseType,
      },
    });
  }

  async update(id: number, dto: UpdateDishDto) {
    await this.ensureExists(id);
    return this.prisma.dish.update({
      where: { id },
      data: {
        title: dto.title,
        description: dto.description,
        photo_url: dto.photoUrl,
        course_type: dto.courseType,
      },
    });
  }

  async delete(id: number) {
    await this.ensureExists(id);
    await this.prisma.dish.delete({ where: { id } });
    return { message: 'Dish deleted successfully' };
  }

  private async ensureExists(id: number) {
    const exists = await this.prisma.dish.findUnique({ where: { id } });
    if (!exists) throw new NotFoundException('Dish not found');
  }
}
