import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { MenuService } from './menu.service';
import { PrismaService } from '../prisma';

describe('MenuService', () => {
  let service: MenuService;
  let prisma: jest.Mocked<PrismaService>;

  const mockMenu = {
    id: 1,
    title: 'Test Menu',
    description: 'A test menu',
    person_min: 2,
    price_per_person: 25,
    remaining_qty: 10,
    status: 'draft',
    Diet: { name: 'Vegan' },
    Theme: { name: 'Italian' },
  };

  beforeEach(async () => {
    const mockPrisma = {
      menu: {
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
        MenuService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<MenuService>(MenuService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return paginated menus', async () => {
      (prisma.menu.findMany as jest.Mock).mockResolvedValue([mockMenu]);
      (prisma.menu.count as jest.Mock).mockResolvedValue(1);

      const result = await service.findAll({ page: 1, limit: 10 });

      expect(result.items).toHaveLength(1);
      expect(result.meta).toBeDefined();
      expect(result.meta.total).toBe(1);
    });

    it('should filter by dietId', async () => {
      (prisma.menu.findMany as jest.Mock).mockResolvedValue([mockMenu]);
      (prisma.menu.count as jest.Mock).mockResolvedValue(1);

      await service.findAll({ page: 1, limit: 10, dietId: 1 });

      expect(prisma.menu.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ diet_id: 1 }),
        }),
      );
    });

    it('should filter by themeId', async () => {
      (prisma.menu.findMany as jest.Mock).mockResolvedValue([mockMenu]);
      (prisma.menu.count as jest.Mock).mockResolvedValue(1);

      await service.findAll({ page: 1, limit: 10, themeId: 2 });

      expect(prisma.menu.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ theme_id: 2 }),
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return menu by id', async () => {
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(mockMenu);

      const result = await service.findById(1);

      expect(result).toEqual(mockMenu);
    });

    it('should throw NotFoundException when menu not found', async () => {
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a new menu', async () => {
      const dto = {
        title: 'New Menu',
        description: 'Description',
        personMin: 2,
        pricePerPerson: 30,
        dietId: 1,
        themeId: 1,
      };
      (prisma.menu.create as jest.Mock).mockResolvedValue({
        ...mockMenu,
        id: 2,
        title: dto.title,
      });

      const result = await service.create(dto, 1);

      expect(prisma.menu.create).toHaveBeenCalled();
      expect(result.title).toBe(dto.title);
    });
  });

  describe('update', () => {
    it('should update a menu', async () => {
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(mockMenu);
      (prisma.menu.update as jest.Mock).mockResolvedValue({
        ...mockMenu,
        title: 'Updated Menu',
      });

      const result = await service.update(1, { title: 'Updated Menu' });

      expect(result.title).toBe('Updated Menu');
    });

    it('should throw if menu not found', async () => {
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.update(999, { title: 'Test' })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('delete', () => {
    it('should delete a menu', async () => {
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(mockMenu);
      (prisma.menu.delete as jest.Mock).mockResolvedValue(mockMenu);

      const result = await service.delete(1);

      expect(result).toHaveProperty('message');
      expect(prisma.menu.delete).toHaveBeenCalledWith({ where: { id: 1 } });
    });

    it('should throw if menu not found for deletion', async () => {
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('publish', () => {
    it('should publish a menu', async () => {
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(mockMenu);
      (prisma.menu.update as jest.Mock).mockResolvedValue({
        ...mockMenu,
        status: 'published',
      });

      const result = await service.publish(1);

      expect(result.status).toBe('published');
    });
  });

  describe('unpublish', () => {
    it('should unpublish a menu', async () => {
      const publishedMenu = { ...mockMenu, status: 'published' };
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue(publishedMenu);
      (prisma.menu.update as jest.Mock).mockResolvedValue({
        ...mockMenu,
        status: 'draft',
      });

      const result = await service.unpublish(1);

      expect(result.status).toBe('draft');
    });
  });
});
