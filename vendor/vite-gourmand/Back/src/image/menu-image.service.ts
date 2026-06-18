/**
 * Menu Image Service - Handles images for menus
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateMenuImageDto, UpdateMenuImageDto } from './dto/image.dto';

@Injectable()
export class MenuImageService {
  constructor(private readonly prisma: PrismaService) {}

  async findByMenu(menuId: number) {
    return this.prisma.menuImage.findMany({
      where: { menu_id: menuId },
      orderBy: [{ is_primary: 'desc' }, { display_order: 'asc' }],
    });
  }

  async findById(id: number) {
    const image = await this.prisma.menuImage.findUnique({ where: { id } });
    if (!image) throw new NotFoundException('Menu image not found');
    return image;
  }

  async create(dto: CreateMenuImageDto) {
    await this.verifyMenuExists(dto.menu_id);
    if (dto.is_primary) await this.unsetPrimary(dto.menu_id);

    return this.prisma.menuImage.create({
      data: {
        menu_id: dto.menu_id,
        image_url: dto.image_url,
        alt_text: dto.alt_text,
        is_primary: dto.is_primary ?? false,
        display_order: dto.display_order ?? 0,
      },
    });
  }

  async update(id: number, dto: UpdateMenuImageDto) {
    const image = await this.findById(id);
    if (dto.is_primary) await this.unsetPrimaryExcept(image.menu_id, id);

    return this.prisma.menuImage.update({ where: { id }, data: dto });
  }

  async setPrimary(id: number) {
    const image = await this.findById(id);
    await this.unsetPrimary(image.menu_id);
    return this.prisma.menuImage.update({
      where: { id },
      data: { is_primary: true },
    });
  }

  async delete(id: number) {
    await this.findById(id);
    await this.prisma.menuImage.delete({ where: { id } });
    return { message: 'Menu image deleted successfully' };
  }

  async reorder(menuId: number, imageIds: number[]) {
    const updates = imageIds.map((imgId, idx) =>
      this.prisma.menuImage.update({
        where: { id: imgId },
        data: { display_order: idx },
      }),
    );
    await this.prisma.$transaction(updates);
    return this.findByMenu(menuId);
  }

  private async verifyMenuExists(menuId: number) {
    const menu = await this.prisma.menu.findUnique({ where: { id: menuId } });
    if (!menu) throw new NotFoundException('Menu not found');
  }

  private async unsetPrimary(menuId: number) {
    await this.prisma.menuImage.updateMany({
      where: { menu_id: menuId, is_primary: true },
      data: { is_primary: false },
    });
  }

  private async unsetPrimaryExcept(menuId: number, excludeId: number) {
    await this.prisma.menuImage.updateMany({
      where: { menu_id: menuId, is_primary: true, id: { not: excludeId } },
      data: { is_primary: false },
    });
  }
}
