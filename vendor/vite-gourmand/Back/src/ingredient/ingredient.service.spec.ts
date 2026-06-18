import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { IngredientService } from './ingredient.service';
import { PrismaService } from '../prisma';

describe('IngredientService', () => {
  let service: IngredientService;
  let prisma: jest.Mocked<PrismaService>;

  const mockIngredient = {
    id: 1,
    name: 'Tomatoes',
    unit: 'kg',
    current_stock: 50,
    min_stock_level: 10,
    cost_per_unit: 2.5,
    last_restocked_at: null,
    created_at: new Date(),
    updated_at: null,
  };

  beforeEach(async () => {
    const mockPrisma = {
      ingredient: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
      dishIngredient: {
        findMany: jest.fn(),
      },
      menuIngredient: {
        findMany: jest.fn(),
      },
      $queryRaw: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        IngredientService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<IngredientService>(IngredientService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return all ingredients', async () => {
      (prisma.ingredient.findMany as jest.Mock).mockResolvedValue([
        mockIngredient,
      ]);

      const result = (await service.findAll()) as any[];

      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('Tomatoes');
    });

    it('should return low stock ingredients when lowStockOnly is true', async () => {
      (prisma.$queryRaw as jest.Mock).mockResolvedValue([mockIngredient]);

      await service.findAll({ lowStockOnly: true });

      expect(prisma.$queryRaw).toHaveBeenCalled();
    });
  });

  describe('findById', () => {
    it('should return an ingredient by id', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(
        mockIngredient,
      );

      const result = await service.findById(1);

      expect(result).toEqual(mockIngredient);
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create an ingredient', async () => {
      const createDto = {
        name: 'Onions',
        unit: 'kg',
        currentStock: 30,
        minStockLevel: 5,
        costPerUnit: 1.5,
      };
      (prisma.ingredient.create as jest.Mock).mockResolvedValue({
        id: 2,
        name: createDto.name,
        unit: createDto.unit,
        current_stock: createDto.currentStock,
        min_stock_level: createDto.minStockLevel,
        cost_per_unit: createDto.costPerUnit,
      });

      const result = await service.create(createDto);

      expect(result.name).toBe('Onions');
    });
  });

  describe('update', () => {
    it('should update an ingredient', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(
        mockIngredient,
      );
      (prisma.ingredient.update as jest.Mock).mockResolvedValue({
        ...mockIngredient,
        current_stock: 100,
      });

      const result = await service.update(1, { currentStock: 100 });

      expect(result.current_stock).toBe(100);
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.update(999, { name: 'Test' })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('delete', () => {
    it('should delete an ingredient', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(
        mockIngredient,
      );
      (prisma.ingredient.delete as jest.Mock).mockResolvedValue(mockIngredient);

      const result = await service.delete(1);

      expect(result.message).toBe('Ingredient deleted successfully');
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('getLowStock', () => {
    it('should return low stock ingredients', async () => {
      const lowStockIngredient = { ...mockIngredient, current_stock: 5 };
      (prisma.$queryRaw as jest.Mock).mockResolvedValue([lowStockIngredient]);

      const result = await service.getLowStock();

      expect(result).toHaveLength(1);
    });
  });

  describe('restock', () => {
    it('should add stock to ingredient', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(
        mockIngredient,
      );
      (prisma.ingredient.update as jest.Mock).mockResolvedValue({
        ...mockIngredient,
        current_stock: 70,
      });

      const result = await service.restock(1, { quantity: 20 });

      expect(result.current_stock).toBe(70);
    });

    it('should throw NotFoundException if ingredient not found', async () => {
      (prisma.ingredient.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.restock(999, { quantity: 20 })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('getUsageForDish', () => {
    it('should return ingredients for a dish', async () => {
      (prisma.dishIngredient.findMany as jest.Mock).mockResolvedValue([
        { Ingredient: mockIngredient, quantity_per_person: 0.2 },
      ]);

      const result = await service.getUsageForDish(1);

      expect(result).toHaveLength(1);
      expect(result[0].Ingredient.name).toBe('Tomatoes');
    });
  });

  describe('getUsageForMenu', () => {
    it('should return ingredients for a menu', async () => {
      (prisma.menuIngredient.findMany as jest.Mock).mockResolvedValue([
        { Ingredient: mockIngredient, quantity_per_serving: 0.3 },
      ]);

      const result = await service.getUsageForMenu(1);

      expect(result).toHaveLength(1);
    });
  });
});
