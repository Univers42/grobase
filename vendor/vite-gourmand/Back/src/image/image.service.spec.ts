/**
 * Image Service Unit Tests (Facade)
 */
import { Test, TestingModule } from '@nestjs/testing';
import { ImageService } from './image.service';
import { MenuImageService } from './menu-image.service';
import { ReviewImageService } from './review-image.service';

describe('ImageService', () => {
  let service: ImageService;
  let menuImageService: jest.Mocked<MenuImageService>;
  let reviewImageService: jest.Mocked<ReviewImageService>;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ImageService,
        {
          provide: MenuImageService,
          useValue: {
            findByMenu: jest.fn(),
            create: jest.fn(),
            delete: jest.fn(),
          },
        },
        {
          provide: ReviewImageService,
          useValue: {
            findByReview: jest.fn(),
            create: jest.fn(),
            delete: jest.fn(),
          },
        },
      ],
    }).compile();
    service = module.get<ImageService>(ImageService);
    menuImageService = module.get(MenuImageService);
    reviewImageService = module.get(ReviewImageService);
    jest.clearAllMocks();
  });

  describe('delegation', () => {
    it('should delegate getMenuItemImages to MenuImageService', async () => {
      await service.getMenuItemImages(1);
      expect(menuImageService.findByMenu).toHaveBeenCalledWith(1);
    });

    it('should delegate getReviewImages to ReviewImageService', async () => {
      await service.getReviewImages(1);
      expect(reviewImageService.findByReview).toHaveBeenCalledWith(1);
    });

    it('should delegate createMenuImage to MenuImageService', async () => {
      const dto = { menu_id: 1, image_url: 'http://test.com' };
      await service.createMenuImage(dto);
      expect(menuImageService.create).toHaveBeenCalledWith(dto);
    });

    it('should delegate createReviewImage to ReviewImageService', async () => {
      const dto = { review_id: 1, image_url: 'http://test.com' };
      await service.createReviewImage(dto, 1);
      expect(reviewImageService.create).toHaveBeenCalledWith(dto, 1);
    });
  });
});
