import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { ReviewService } from './review.service';
import { PrismaService } from '../prisma';

describe('ReviewService', () => {
  let service: ReviewService;
  let prisma: jest.Mocked<PrismaService>;

  const mockReview = {
    id: 1,
    note: 5,
    description: 'Great service!',
    status: 'approved',
    user_id: 1,
    created_at: new Date(),
    User: { firstname: 'John', lastname: 'Doe' },
  };

  beforeEach(async () => {
    const mockPrisma = {
      publish: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ReviewService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<ReviewService>(ReviewService);
    prisma = module.get(PrismaService);
  });

  describe('findApproved', () => {
    it('should return approved reviews with pagination', async () => {
      const mockReviews = [mockReview];
      (prisma.publish.findMany as jest.Mock).mockResolvedValue(mockReviews);
      (prisma.publish.count as jest.Mock).mockResolvedValue(1);

      const result = await service.findApproved({ page: 1, limit: 10 });

      expect(result.items).toEqual(mockReviews);
      expect(result.meta).toBeDefined();
      expect(result.meta.total).toBe(1);
    });
  });

  describe('findPending', () => {
    it('should return pending reviews for moderation', async () => {
      const pendingReview = { ...mockReview, status: 'pending' };
      (prisma.publish.findMany as jest.Mock).mockResolvedValue([pendingReview]);
      (prisma.publish.count as jest.Mock).mockResolvedValue(1);

      const result = await service.findPending({ page: 1, limit: 10 });

      expect(result.items).toHaveLength(1);
      expect(prisma.publish.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { status: 'pending' },
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return a review by id', async () => {
      (prisma.publish.findUnique as jest.Mock).mockResolvedValue(mockReview);

      const result = await service.findById(1);

      expect(result).toEqual(mockReview);
    });

    it('should throw NotFoundException if review not found', async () => {
      (prisma.publish.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a new review', async () => {
      const dto = { note: 5, description: 'Amazing!' };
      (prisma.publish.create as jest.Mock).mockResolvedValue({
        id: 2,
        ...dto,
        user_id: 1,
      });

      const result = await service.create(1, dto);

      expect(result.note).toBe(5);
      expect(prisma.publish.create).toHaveBeenCalled();
    });
  });

  describe('moderate', () => {
    it('should approve a review', async () => {
      const moderated = { ...mockReview, status: 'approved' };
      (prisma.publish.findUnique as jest.Mock).mockResolvedValue(mockReview);
      (prisma.publish.update as jest.Mock).mockResolvedValue(moderated);

      const result = await service.moderate(1, 2, { status: 'approved' });

      expect(result.status).toBe('approved');
    });

    it('should reject a review with reason', async () => {
      const dto = { status: 'rejected' as const, rejectionReason: 'Spam' };
      const rejected = { ...mockReview, status: 'rejected' };
      (prisma.publish.findUnique as jest.Mock).mockResolvedValue(mockReview);
      (prisma.publish.update as jest.Mock).mockResolvedValue(rejected);

      await service.moderate(1, 2, dto);

      expect(prisma.publish.update).toHaveBeenCalled();
    });

    it('should throw if review not found for moderation', async () => {
      (prisma.publish.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(
        service.moderate(999, 2, { status: 'approved' }),
      ).rejects.toThrow(NotFoundException);
    });
  });
});
