/**
 * Image Service - Facade delegating to MenuImage and ReviewImage services
 */
import { Injectable } from '@nestjs/common';
import { MenuImageService } from './menu-image.service';
import { ReviewImageService } from './review-image.service';
import {
  CreateMenuImageDto,
  UpdateMenuImageDto,
  CreateReviewImageDto,
} from './dto/image.dto';

@Injectable()
export class ImageService {
  constructor(
    private readonly menuImageService: MenuImageService,
    private readonly reviewImageService: ReviewImageService,
  ) {}

  // Menu Images - delegate to MenuImageService
  getMenuItemImages(menuId: number) {
    return this.menuImageService.findByMenu(menuId);
  }
  getMenuImageById(id: number) {
    return this.menuImageService.findById(id);
  }
  createMenuImage(dto: CreateMenuImageDto) {
    return this.menuImageService.create(dto);
  }
  updateMenuImage(id: number, dto: UpdateMenuImageDto) {
    return this.menuImageService.update(id, dto);
  }
  setMenuImageAsPrimary(id: number) {
    return this.menuImageService.setPrimary(id);
  }
  deleteMenuImage(id: number) {
    return this.menuImageService.delete(id);
  }
  reorderMenuImages(menuId: number, ids: number[]) {
    return this.menuImageService.reorder(menuId, ids);
  }

  // Review Images - delegate to ReviewImageService
  getReviewImages(reviewId: number) {
    return this.reviewImageService.findByReview(reviewId);
  }
  getReviewImageById(id: number) {
    return this.reviewImageService.findById(id);
  }
  createReviewImage(dto: CreateReviewImageDto, userId: number) {
    return this.reviewImageService.create(dto, userId);
  }
  createReviewImageAdmin(dto: CreateReviewImageDto) {
    return this.reviewImageService.createAdmin(dto);
  }
  updateReviewImage(id: number) {
    // Review images only have a URL; "updating" returns the current image
    return this.reviewImageService.findById(id);
  }
  deleteReviewImage(id: number, userId: number) {
    return this.reviewImageService.delete(id, userId);
  }
  deleteReviewImageAdmin(id: number) {
    return this.reviewImageService.deleteAdmin(id);
  }
}
