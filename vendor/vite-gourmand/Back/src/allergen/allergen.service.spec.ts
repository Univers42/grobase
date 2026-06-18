import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { AllergenService } from './allergen.service';
import { PrismaService } from '../prisma';

describe('AllergenService', () => {
  let service: AllergenService;
  let prisma: jest.Mocked<PrismaService>;

  const mockAllergen = {
    id: 1,
    name: 'Peanuts',
    icon_url: 'https://example.com/peanuts.png',
  };

  beforeEach(async () => {
    const mockPrisma = {
      allergen: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        AllergenService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<AllergenService>(AllergenService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return all allergens ordered by name', async () => {
      const allergens = [mockAllergen, { id: 2, name: 'Gluten' }];
      (prisma.allergen.findMany as jest.Mock).mockResolvedValue(allergens);

      const result = await service.findAll();

      expect(result).toEqual(allergens);
      expect(prisma.allergen.findMany).toHaveBeenCalledWith({
        orderBy: { name: 'asc' },
      });
    });
  });

  describe('findById', () => {
    it('should return allergen by id', async () => {
      (prisma.allergen.findUnique as jest.Mock).mockResolvedValue(mockAllergen);

      const result = await service.findById(1);

      expect(result).toEqual(mockAllergen);
    });

    it('should throw NotFoundException when allergen not found', async () => {
      (prisma.allergen.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a new allergen', async () => {
      const dto = { name: 'Milk', iconUrl: 'milk.png' };
      (prisma.allergen.create as jest.Mock).mockResolvedValue({
        id: 3,
        name: dto.name,
        icon_url: dto.iconUrl,
      });

      const result = await service.create(dto);

      expect(result.name).toBe('Milk');
      expect(prisma.allergen.create).toHaveBeenCalled();
    });
  });

  describe('update', () => {
    it('should update an allergen', async () => {
      (prisma.allergen.findUnique as jest.Mock).mockResolvedValue(mockAllergen);
      (prisma.allergen.update as jest.Mock).mockResolvedValue({
        ...mockAllergen,
        name: 'Tree Nuts',
      });

      const result = await service.update(1, { name: 'Tree Nuts' });

      expect(result.name).toBe('Tree Nuts');
    });

    it('should throw if allergen not found', async () => {
      (prisma.allergen.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.update(999, { name: 'Test' })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('delete', () => {
    it('should delete an allergen', async () => {
      (prisma.allergen.findUnique as jest.Mock).mockResolvedValue(mockAllergen);
      (prisma.allergen.delete as jest.Mock).mockResolvedValue(mockAllergen);

      const result = await service.delete(1);

      expect(result).toHaveProperty('message');
    });

    it('should throw if allergen not found for deletion', async () => {
      (prisma.allergen.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });
});
