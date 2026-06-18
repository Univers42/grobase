/**
 * Menu Image Service
 * Handle menu image uploads and management
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';

interface CreateImageDto {
  imageUrl: string;
  altText?: string;
  displayOrder?: number;
  isPrimary?: boolean;
}

@Injectable()
export class MenuImageService {
  constructor(private readonly prisma: PrismaService) {}

  async findByMenu(menuId: number) {
    return this.prisma.menuImage.findMany({
      where: { menu_id: menuId },
      orderBy: [{ is_primary: 'desc' }, { display_order: 'asc' }],
    });
  }

  async addImage(menuId: number, dto: CreateImageDto) {
    await this.ensureMenuExists(menuId);

    if (dto.isPrimary) {
      await this.clearPrimaryImage(menuId);
    }

    return this.prisma.menuImage.create({
      data: {
        menu_id: menuId,
        image_url: dto.imageUrl,
        alt_text: dto.altText,
        display_order: dto.displayOrder ?? 0,
        is_primary: dto.isPrimary ?? false,
      },
    });
  }

  async deleteImage(menuId: number, imageId: number) {
    const image = await this.prisma.menuImage.findFirst({
      where: { id: imageId, menu_id: menuId },
    });

    if (!image) throw new NotFoundException('Image not found');

    await this.prisma.menuImage.delete({ where: { id: imageId } });
    return { message: 'Image deleted successfully' };
  }

  async setPrimaryImage(menuId: number, imageId: number) {
    await this.clearPrimaryImage(menuId);
    return this.prisma.menuImage.update({
      where: { id: imageId },
      data: { is_primary: true },
    });
  }

  private async ensureMenuExists(menuId: number) {
    const menu = await this.prisma.menu.findUnique({ where: { id: menuId } });
    if (!menu) throw new NotFoundException('Menu not found');
  }

  private async clearPrimaryImage(menuId: number) {
    await this.prisma.menuImage.updateMany({
      where: { menu_id: menuId, is_primary: true },
      data: { is_primary: false },
    });
  }
}
