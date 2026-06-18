import { Test, TestingModule } from '@nestjs/testing';
import { SeedService } from './seed.service';
import { PrismaService } from '../prisma';
import { UnsplashService } from '../unsplash';

describe('SeedService', () => {
  let service: SeedService;

  const mockPrisma = {
    menu: {
      findMany: jest.fn(),
    },
    menuImage: {
      findFirst: jest.fn(),
      update: jest.fn(),
      create: jest.fn(),
    },
  };

  const mockUnsplash = {
    getRandomPhoto: jest.fn(),
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        SeedService,
        { provide: PrismaService, useValue: mockPrisma },
        { provide: UnsplashService, useValue: mockUnsplash },
      ],
    }).compile();

    service = module.get<SeedService>(SeedService);
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('updateMenuImages', () => {
    it('should update images for existing menus', async () => {
      const menus = [
        { id: 1, title: 'Menu Prestige Mariage' },
        { id: 2, title: 'Menu Végétarien Élégant' },
      ];

      const photo = {
        urls: { regular: 'https://unsplash.com/photo.jpg' },
        alt_description: 'Test photo',
      };

      mockPrisma.menu.findMany.mockResolvedValue(menus);
      mockUnsplash.getRandomPhoto.mockResolvedValue(photo);
      mockPrisma.menuImage.findFirst.mockResolvedValue({ id: 1 });
      mockPrisma.menuImage.update.mockResolvedValue({});

      const result = await service.updateMenuImages();

      expect(result.updated).toBe(2);
      expect(result.errors).toBe(0);
      expect(mockPrisma.menuImage.update).toHaveBeenCalledTimes(2);
    });

    it('should create image if none exists', async () => {
      const menus = [{ id: 1, title: 'Menu Prestige Mariage' }];

      const photo = {
        urls: { regular: 'https://unsplash.com/photo.jpg' },
        alt_description: 'Test photo',
      };

      mockPrisma.menu.findMany.mockResolvedValue(menus);
      mockUnsplash.getRandomPhoto.mockResolvedValue(photo);
      mockPrisma.menuImage.findFirst.mockResolvedValue(null);
      mockPrisma.menuImage.create.mockResolvedValue({});

      const result = await service.updateMenuImages();

      expect(result.updated).toBe(1);
      expect(mockPrisma.menuImage.create).toHaveBeenCalled();
    });

    it('should handle errors gracefully', async () => {
      const menus = [{ id: 1, title: 'Menu Prestige Mariage' }];

      mockPrisma.menu.findMany.mockResolvedValue(menus);
      mockUnsplash.getRandomPhoto.mockRejectedValue(new Error('API error'));

      const result = await service.updateMenuImages();

      expect(result.updated).toBe(0);
      expect(result.errors).toBe(1);
    });
  });
});
