/**
 * Discount Service
 */
import {
  Injectable,
  NotFoundException,
  BadRequestException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import {
  CreateDiscountDto,
  UpdateDiscountDto,
  ValidateDiscountDto,
} from './dto/discount.dto';

@Injectable()
export class DiscountService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(options?: { activeOnly?: boolean }) {
    const where = options?.activeOnly ? { is_active: true } : {};
    return this.prisma.discount.findMany({
      where,
      orderBy: { code: 'asc' },
    });
  }

  async findById(id: number) {
    const discount = await this.prisma.discount.findUnique({ where: { id } });
    if (!discount) throw new NotFoundException('Discount not found');
    return discount;
  }

  async findByCode(code: string) {
    const discount = await this.prisma.discount.findUnique({
      where: { code: code.toUpperCase() },
    });
    if (!discount) throw new NotFoundException('Discount code not found');
    return discount;
  }

  async create(dto: CreateDiscountDto, userId?: number) {
    return this.prisma.discount.create({
      data: {
        code: dto.code.toUpperCase(),
        description: dto.description,
        type: dto.type,
        value: dto.value,
        min_order_amount: dto.minOrderAmount,
        max_uses: dto.maxUses,
        valid_from: dto.validFrom ? new Date(dto.validFrom) : null,
        valid_until: dto.validUntil ? new Date(dto.validUntil) : null,
        is_active: dto.isActive ?? true,
        created_by: userId,
      },
    });
  }

  async update(id: number, dto: UpdateDiscountDto) {
    await this.findById(id);
    return this.prisma.discount.update({
      where: { id },
      data: {
        code: dto.code?.toUpperCase(),
        description: dto.description,
        type: dto.type,
        value: dto.value,
        min_order_amount: dto.minOrderAmount,
        max_uses: dto.maxUses,
        valid_from: dto.validFrom ? new Date(dto.validFrom) : undefined,
        valid_until: dto.validUntil ? new Date(dto.validUntil) : undefined,
        is_active: dto.isActive,
      },
    });
  }

  async delete(id: number) {
    await this.findById(id);
    await this.prisma.discount.delete({ where: { id } });
    return { message: 'Discount deleted successfully' };
  }

  async validate(dto: ValidateDiscountDto) {
    const discount = await this.findByCode(dto.code);
    const now = new Date();
    const errors: string[] = [];

    // Check if active
    if (!discount.is_active) {
      errors.push('Discount code is not active');
    }

    // Check date validity
    if (discount.valid_from && new Date(discount.valid_from) > now) {
      errors.push('Discount code is not yet valid');
    }
    if (discount.valid_until && new Date(discount.valid_until) < now) {
      errors.push('Discount code has expired');
    }

    // Check usage limit
    if (
      discount.max_uses &&
      discount.current_uses &&
      discount.current_uses >= discount.max_uses
    ) {
      errors.push('Discount code has reached maximum uses');
    }

    // Check minimum order amount
    if (
      this.isBelowMinimumOrderAmount(discount.min_order_amount, dto.orderAmount)
    ) {
      errors.push(
        `Minimum order amount is ${String(discount.min_order_amount)}€`,
      );
    }

    if (errors.length > 0) {
      throw new BadRequestException(errors.join('. '));
    }

    // Calculate discount amount
    const discountAmount = this.calculateDiscountAmount(
      discount,
      dto.orderAmount,
    );

    return {
      valid: true,
      discount,
      discountAmount,
      finalAmount: dto.orderAmount ? dto.orderAmount - discountAmount : null,
    };
  }

  async incrementUsage(id: number) {
    return this.prisma.discount.update({
      where: { id },
      data: { current_uses: { increment: 1 } },
    });
  }

  private isBelowMinimumOrderAmount(
    minOrderAmount: unknown,
    orderAmount?: number,
  ): boolean {
    return Boolean(
      minOrderAmount && orderAmount && orderAmount < Number(minOrderAmount),
    );
  }

  private calculateDiscountAmount(
    discount: { type: string; value: unknown },
    orderAmount?: number,
  ): number {
    if (!orderAmount) return 0;
    if (discount.type === 'percentage')
      return (orderAmount * Number(discount.value)) / 100;
    return Number(discount.value);
  }
}
