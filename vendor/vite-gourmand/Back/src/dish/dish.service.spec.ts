import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { DishService } from './dish.service';
import { PrismaService } from '../prisma';

describe('DishService', () => {
  let service: DishService;
  let prisma: jest.Mocked<PrismaService>;

  const mockDish = {
    id: 1,
    title: 'Test Dish',
    description: 'A delicious test dish',
    photo_url: 'https://example.com/dish.jpg',
    course_type: 'main',
    Allergen: [],
  };

  beforeEach(async () => {
    const mockPrisma = {
      dish: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DishService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<DishService>(DishService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return paginated dishes', async () => {
      (prisma.dish.findMany as jest.Mock).mockResolvedValue([mockDish]);
      (prisma.dish.count as jest.Mock).mockResolvedValue(1);

      const result = await service.findAll({ page: 1, limit: 10 });

      expect(result.items).toHaveLength(1);
      expect(result.meta).toBeDefined();
      expect(result.meta.total).toBe(1);
    });

    it('should handle empty results', async () => {
      (prisma.dish.findMany as jest.Mock).mockResolvedValue([]);
      (prisma.dish.count as jest.Mock).mockResolvedValue(0);

      const result = await service.findAll({ page: 1, limit: 10 });

      expect(result.items).toHaveLength(0);
      expect(result.meta.total).toBe(0);
    });
  });

  describe('findById', () => {
    it('should return dish by id with allergens and ingredients', async () => {
      const dishWithDetails = {
        ...mockDish,
        DishIngredient: [{ Ingredient: { name: 'Salt' } }],
      };
      (prisma.dish.findUnique as jest.Mock).mockResolvedValue(dishWithDetails);

      const result = await service.findById(1);

      expect(result).toEqual(dishWithDetails);
      expect(prisma.dish.findUnique).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 1 },
          include: expect.objectContaining({
            Allergen: true,
            DishIngredient: expect.anything(),
          }),
        }),
      );
    });

    it('should throw NotFoundException when dish not found', async () => {
      (prisma.dish.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a new dish', async () => {
      const dto = {
        title: 'New Dish',
        description: 'Fresh dish',
        photoUrl: 'https://example.com/new.jpg',
        courseType: 'starter',
      };
      (prisma.dish.create as jest.Mock).mockResolvedValue({
        id: 2,
        title: dto.title,
        description: dto.description,
      });

      const result = await service.create(dto);

      expect(result.title).toBe(dto.title);
      expect(prisma.dish.create).toHaveBeenCalled();
    });
  });

  describe('update', () => {
    it('should update a dish', async () => {
      (prisma.dish.findUnique as jest.Mock).mockResolvedValue(mockDish);
      (prisma.dish.update as jest.Mock).mockResolvedValue({
        ...mockDish,
        title: 'Updated Dish',
      });

      const result = await service.update(1, { title: 'Updated Dish' });

      expect(result.title).toBe('Updated Dish');
    });

    it('should throw if dish not found', async () => {
      (prisma.dish.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.update(999, { title: 'Test' })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('delete', () => {
    it('should delete a dish', async () => {
      (prisma.dish.findUnique as jest.Mock).mockResolvedValue(mockDish);
      (prisma.dish.delete as jest.Mock).mockResolvedValue(mockDish);

      const result = await service.delete(1);

      expect(result).toHaveProperty('message');
      expect(prisma.dish.delete).toHaveBeenCalledWith({ where: { id: 1 } });
    });

    it('should throw if dish not found for deletion', async () => {
      (prisma.dish.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });
});
