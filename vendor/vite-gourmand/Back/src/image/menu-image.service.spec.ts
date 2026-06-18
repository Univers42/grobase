/**
 * Menu Image Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { MenuImageService } from './menu-image.service';
import { PrismaService } from '../prisma';
import { NotFoundException } from '@nestjs/common';

describe('MenuImageService', () => {
  let service: MenuImageService;

  const mockImage = {
    id: 1,
    menu_id: 1,
    image_url: 'http://test.com/img.jpg',
    is_primary: true,
    display_order: 0,
  };
  const mockPrisma = {
    menuImage: {
      findMany: jest.fn(),
      findUnique: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
      delete: jest.fn(),
    },
    menu: { findUnique: jest.fn() },
    $transaction: jest.fn((fns) => Promise.all(fns)),
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        MenuImageService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<MenuImageService>(MenuImageService);
    jest.clearAllMocks();
  });

  describe('findByMenu', () => {
    it('should return images for menu', async () => {
      mockPrisma.menuImage.findMany.mockResolvedValue([mockImage]);
      const result = await service.findByMenu(1);
      expect(result).toEqual([mockImage]);
    });
  });

  describe('create', () => {
    it('should create menu image', async () => {
      mockPrisma.menu.findUnique.mockResolvedValue({ id: 1 });
      mockPrisma.menuImage.create.mockResolvedValue(mockImage);
      const result = await service.create({
        menu_id: 1,
        image_url: 'http://test.com/img.jpg',
      });
      expect(result).toEqual(mockImage);
    });

    it('should throw NotFoundException when menu not found', async () => {
      mockPrisma.menu.findUnique.mockResolvedValue(null);
      await expect(
        service.create({ menu_id: 999, image_url: 'http://test.com' }),
      ).rejects.toThrow(NotFoundException);
    });
  });

  describe('setPrimary', () => {
    it('should set image as primary', async () => {
      mockPrisma.menuImage.findUnique.mockResolvedValue(mockImage);
      mockPrisma.menuImage.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.menuImage.update.mockResolvedValue({
        ...mockImage,
        is_primary: true,
      });
      const result = await service.setPrimary(1);
      expect(result.is_primary).toBe(true);
    });
  });
});
