import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { DietService } from './diet.service';
import { PrismaService } from '../prisma';

describe('DietService', () => {
  let service: DietService;
  let prisma: jest.Mocked<PrismaService>;

  const mockDiet = {
    id: 1,
    name: 'Vegan',
    description: 'Plant-based diet',
    icon_url: 'https://example.com/vegan.png',
  };

  beforeEach(async () => {
    const mockPrisma = {
      diet: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DietService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<DietService>(DietService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return all diets ordered by name', async () => {
      const diets = [mockDiet, { id: 2, name: 'Vegetarian' }];
      (prisma.diet.findMany as jest.Mock).mockResolvedValue(diets);

      const result = await service.findAll();

      expect(result).toEqual(diets);
      expect(prisma.diet.findMany).toHaveBeenCalledWith({
        orderBy: { name: 'asc' },
      });
    });
  });

  describe('findById', () => {
    it('should return diet by id', async () => {
      (prisma.diet.findUnique as jest.Mock).mockResolvedValue(mockDiet);

      const result = await service.findById(1);

      expect(result).toEqual(mockDiet);
    });

    it('should throw NotFoundException when diet not found', async () => {
      (prisma.diet.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a new diet', async () => {
      const dto = {
        name: 'Keto',
        description: 'Low carb',
        iconUrl: 'keto.png',
      };
      (prisma.diet.create as jest.Mock).mockResolvedValue({
        id: 3,
        name: dto.name,
        description: dto.description,
        icon_url: dto.iconUrl,
      });

      const result = await service.create(dto);

      expect(result.name).toBe('Keto');
      expect(prisma.diet.create).toHaveBeenCalled();
    });
  });

  describe('update', () => {
    it('should update a diet', async () => {
      (prisma.diet.findUnique as jest.Mock).mockResolvedValue(mockDiet);
      (prisma.diet.update as jest.Mock).mockResolvedValue({
        ...mockDiet,
        name: 'Updated Vegan',
      });

      const result = await service.update(1, { name: 'Updated Vegan' });

      expect(result.name).toBe('Updated Vegan');
    });

    it('should throw if diet not found', async () => {
      (prisma.diet.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.update(999, { name: 'Test' })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('delete', () => {
    it('should delete a diet', async () => {
      (prisma.diet.findUnique as jest.Mock).mockResolvedValue(mockDiet);
      (prisma.diet.delete as jest.Mock).mockResolvedValue(mockDiet);

      const result = await service.delete(1);

      expect(result).toHaveProperty('message');
    });

    it('should throw if diet not found for deletion', async () => {
      (prisma.diet.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });
});
