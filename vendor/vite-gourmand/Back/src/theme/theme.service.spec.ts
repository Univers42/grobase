import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { ThemeService } from './theme.service';
import { PrismaService } from '../prisma';

describe('ThemeService', () => {
  let service: ThemeService;
  let prisma: jest.Mocked<PrismaService>;

  const mockTheme = {
    id: 1,
    name: 'Italian',
    description: 'Traditional Italian cuisine',
    icon_url: 'https://example.com/italian.png',
  };

  beforeEach(async () => {
    const mockPrisma = {
      theme: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ThemeService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<ThemeService>(ThemeService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return all themes ordered by name', async () => {
      const themes = [mockTheme, { id: 2, name: 'French' }];
      (prisma.theme.findMany as jest.Mock).mockResolvedValue(themes);

      const result = await service.findAll();

      expect(result).toEqual(themes);
      expect(prisma.theme.findMany).toHaveBeenCalledWith({
        orderBy: { name: 'asc' },
      });
    });
  });

  describe('findById', () => {
    it('should return theme by id', async () => {
      (prisma.theme.findUnique as jest.Mock).mockResolvedValue(mockTheme);

      const result = await service.findById(1);

      expect(result).toEqual(mockTheme);
    });

    it('should throw NotFoundException when theme not found', async () => {
      (prisma.theme.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a new theme', async () => {
      const dto = {
        name: 'Japanese',
        description: 'Japanese cuisine',
        iconUrl: 'japanese.png',
      };
      (prisma.theme.create as jest.Mock).mockResolvedValue({
        id: 3,
        name: dto.name,
        description: dto.description,
        icon_url: dto.iconUrl,
      });

      const result = await service.create(dto);

      expect(result.name).toBe('Japanese');
      expect(prisma.theme.create).toHaveBeenCalled();
    });
  });

  describe('update', () => {
    it('should update a theme', async () => {
      (prisma.theme.findUnique as jest.Mock).mockResolvedValue(mockTheme);
      (prisma.theme.update as jest.Mock).mockResolvedValue({
        ...mockTheme,
        name: 'Mediterranean',
      });

      const result = await service.update(1, { name: 'Mediterranean' });

      expect(result.name).toBe('Mediterranean');
    });

    it('should throw if theme not found', async () => {
      (prisma.theme.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.update(999, { name: 'Test' })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('delete', () => {
    it('should delete a theme', async () => {
      (prisma.theme.findUnique as jest.Mock).mockResolvedValue(mockTheme);
      (prisma.theme.delete as jest.Mock).mockResolvedValue(mockTheme);

      const result = await service.delete(1);

      expect(result).toHaveProperty('message');
    });

    it('should throw if theme not found for deletion', async () => {
      (prisma.theme.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });
});
