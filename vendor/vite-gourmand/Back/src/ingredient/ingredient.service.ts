/**
 * Ingredient Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import {
  CreateIngredientDto,
  UpdateIngredientDto,
  RestockIngredientDto,
} from './dto/ingredient.dto';

@Injectable()
export class IngredientService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(options?: { lowStockOnly?: boolean }) {
    const where = {};
    if (options?.lowStockOnly) {
      // Using raw query to compare fields - Prisma doesn't support direct field comparison
      return this.prisma.$queryRaw`
        SELECT * FROM "Ingredient" 
        WHERE "current_stock" <= "min_stock_level"
        ORDER BY "name" ASC
      `;
    }
    return this.prisma.ingredient.findMany({
      where,
      orderBy: { name: 'asc' },
    });
  }

  async findById(id: number) {
    const ingredient = await this.prisma.ingredient.findUnique({
      where: { id },
    });
    if (!ingredient) throw new NotFoundException('Ingredient not found');
    return ingredient;
  }

  async create(dto: CreateIngredientDto) {
    return this.prisma.ingredient.create({
      data: {
        name: dto.name,
        unit: dto.unit,
        current_stock: dto.currentStock,
        min_stock_level: dto.minStockLevel,
        cost_per_unit: dto.costPerUnit,
      },
    });
  }

  async update(id: number, dto: UpdateIngredientDto) {
    await this.findById(id);
    return this.prisma.ingredient.update({
      where: { id },
      data: {
        name: dto.name,
        unit: dto.unit,
        current_stock: dto.currentStock,
        min_stock_level: dto.minStockLevel,
        cost_per_unit: dto.costPerUnit,
        updated_at: new Date(),
      },
    });
  }

  async delete(id: number) {
    await this.findById(id);
    await this.prisma.ingredient.delete({ where: { id } });
    return { message: 'Ingredient deleted successfully' };
  }

  async restock(id: number, dto: RestockIngredientDto) {
    const ingredient = await this.findById(id);
    const newStock = Number(ingredient.current_stock || 0) + dto.quantity;

    return this.prisma.ingredient.update({
      where: { id },
      data: {
        current_stock: newStock,
        last_restocked_at: new Date(),
        updated_at: new Date(),
      },
    });
  }

  async getLowStock() {
    return this.findAll({ lowStockOnly: true });
  }

  async getUsageForDish(dishId: number) {
    return this.prisma.dishIngredient.findMany({
      where: { dish_id: dishId },
      include: { Ingredient: true },
    });
  }

  async getUsageForMenu(menuId: number) {
    return this.prisma.menuIngredient.findMany({
      where: { menu_id: menuId },
      include: { Ingredient: true },
    });
  }
}
