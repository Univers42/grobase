/**
 * Review Image Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { ReviewImageService } from './review-image.service';
import { PrismaService } from '../prisma';
import {
  NotFoundException,
  ForbiddenException,
  BadRequestException,
} from '@nestjs/common';

describe('ReviewImageService', () => {
  let service: ReviewImageService;

  const mockImage = {
    id: 1,
    review_id: 1,
    image_url: 'http://test.com/img.jpg',
    uploaded_at: new Date(),
  };
  const mockReview = { id: 1, user_id: 1 };
  const mockPrisma = {
    reviewImage: {
      findMany: jest.fn(),
      findUnique: jest.fn(),
      create: jest.fn(),
      delete: jest.fn(),
      count: jest.fn(),
    },
    publish: { findUnique: jest.fn() },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ReviewImageService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<ReviewImageService>(ReviewImageService);
    jest.clearAllMocks();
  });

  describe('create', () => {
    it('should create review image', async () => {
      mockPrisma.publish.findUnique.mockResolvedValue(mockReview);
      mockPrisma.reviewImage.count.mockResolvedValue(0);
      mockPrisma.reviewImage.create.mockResolvedValue(mockImage);
      const result = await service.create(
        { review_id: 1, image_url: 'http://test.com/img.jpg' },
        1,
      );
      expect(result).toEqual(mockImage);
    });

    it('should throw NotFoundException when review not found', async () => {
      mockPrisma.publish.findUnique.mockResolvedValue(null);
      await expect(
        service.create({ review_id: 999, image_url: 'http://test.com' }, 1),
      ).rejects.toThrow(NotFoundException);
    });

    it('should throw ForbiddenException when not owner', async () => {
      mockPrisma.publish.findUnique.mockResolvedValue({
        ...mockReview,
        user_id: 99,
      });
      await expect(
        service.create({ review_id: 1, image_url: 'http://test.com' }, 1),
      ).rejects.toThrow(ForbiddenException);
    });

    it('should throw BadRequestException when max images reached', async () => {
      mockPrisma.publish.findUnique.mockResolvedValue(mockReview);
      mockPrisma.reviewImage.count.mockResolvedValue(5);
      await expect(
        service.create({ review_id: 1, image_url: 'http://test.com' }, 1),
      ).rejects.toThrow(BadRequestException);
    });
  });

  describe('delete', () => {
    it('should delete review image', async () => {
      mockPrisma.reviewImage.findUnique.mockResolvedValue(mockImage);
      mockPrisma.publish.findUnique.mockResolvedValue(mockReview);
      mockPrisma.reviewImage.delete.mockResolvedValue(mockImage);
      await service.delete(1, 1);
      expect(mockPrisma.reviewImage.delete).toHaveBeenCalled();
    });
  });
});
