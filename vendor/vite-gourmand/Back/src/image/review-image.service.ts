/**
 * Review Image Service - Handles images for reviews (Publish model)
 */
import {
  Injectable,
  NotFoundException,
  ForbiddenException,
  BadRequestException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateReviewImageDto } from './dto/image.dto';

const MAX_IMAGES_PER_REVIEW = 5;

@Injectable()
export class ReviewImageService {
  constructor(private readonly prisma: PrismaService) {}

  async findByReview(reviewId: number) {
    return this.prisma.reviewImage.findMany({
      where: { review_id: reviewId },
      orderBy: { uploaded_at: 'asc' },
    });
  }

  async findById(id: number) {
    const image = await this.prisma.reviewImage.findUnique({ where: { id } });
    if (!image) throw new NotFoundException('Review image not found');
    return image;
  }

  async create(dto: CreateReviewImageDto, userId: number) {
    const review = await this.getReviewOrFail(dto.review_id);
    this.verifyOwnership(review.user_id, userId);
    await this.checkImageLimit(dto.review_id);

    return this.prisma.reviewImage.create({
      data: {
        review_id: dto.review_id,
        image_url: dto.image_url,
      },
    });
  }

  async createAdmin(dto: CreateReviewImageDto) {
    await this.getReviewOrFail(dto.review_id);
    return this.prisma.reviewImage.create({
      data: {
        review_id: dto.review_id,
        image_url: dto.image_url,
      },
    });
  }

  async delete(id: number, userId: number) {
    const image = await this.findById(id);
    const review = await this.getReviewOrFail(image.review_id);
    this.verifyOwnership(review.user_id, userId);

    await this.prisma.reviewImage.delete({ where: { id } });
    return { message: 'Review image deleted successfully' };
  }

  async deleteAdmin(id: number) {
    await this.findById(id);
    await this.prisma.reviewImage.delete({ where: { id } });
    return { message: 'Review image deleted successfully' };
  }

  private async getReviewOrFail(reviewId: number) {
    const review = await this.prisma.publish.findUnique({
      where: { id: reviewId },
    });
    if (!review) throw new NotFoundException('Review not found');
    return review;
  }

  private verifyOwnership(ownerId: number, userId: number) {
    if (ownerId !== userId) {
      throw new ForbiddenException('Not authorized for this review');
    }
  }

  private async checkImageLimit(reviewId: number) {
    const count = await this.prisma.reviewImage.count({
      where: { review_id: reviewId },
    });
    if (count >= MAX_IMAGES_PER_REVIEW) {
      throw new BadRequestException(`Max ${MAX_IMAGES_PER_REVIEW} images`);
    }
  }
}
