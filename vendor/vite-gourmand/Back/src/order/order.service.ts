/**
 * Order Service
 * Core order management logic
 */
import {
  Injectable,
  NotFoundException,
  ForbiddenException,
  BadRequestException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import {
  CreateOrderDto,
  UpdateOrderDto,
  OrderFilterDto,
} from './dto/order.dto';
import { buildPaginationMeta, JwtPayload } from '../common';

@Injectable()
export class OrderService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(filters: OrderFilterDto) {
    const { page = 1, limit = 20, status } = filters;
    const skip = (page - 1) * limit;
    const where = status ? { status } : {};

    const [orders, total] = await Promise.all([
      this.prisma.order.findMany({
        where,
        skip,
        take: limit,
        orderBy: { created_at: 'desc' },
        include: this.getOrderIncludes(),
      }),
      this.prisma.order.count({ where }),
    ]);

    return { items: orders, meta: buildPaginationMeta(page, limit, total) };
  }

  async findByUser(userId: number, filters: OrderFilterDto) {
    const { page = 1, limit = 20 } = filters;
    const where = { user_id: userId };

    const [orders, total] = await Promise.all([
      this.prisma.order.findMany({
        where,
        skip: (page - 1) * limit,
        take: limit,
        orderBy: { created_at: 'desc' },
        include: this.getOrderIncludes(),
      }),
      this.prisma.order.count({ where }),
    ]);

    return { items: orders, meta: buildPaginationMeta(page, limit, total) };
  }

  async findById(id: number, user: JwtPayload) {
    const order = await this.prisma.order.findUnique({
      where: { id },
      include: this.getOrderIncludes(),
    });

    if (!order) throw new NotFoundException('Order not found');
    this.ensureAccess(order, user);
    return order;
  }

  async create(userId: number, dto: CreateOrderDto) {
    const orderNumber = this.generateOrderNumber();
    const order = await this.prisma.order.create({
      data: {
        order_number: orderNumber,
        user_id: userId,
        delivery_date: new Date(dto.deliveryDate),
        delivery_hour: dto.deliveryHour,
        delivery_address: dto.deliveryAddress,
        person_number: dto.personNumber,
        menu_price: dto.menuPrice,
        total_price: dto.totalPrice,
        special_instructions: dto.specialInstructions,
      },
      include: this.getOrderIncludes(),
    });

    // Link menu to order via OrderMenu junction table
    if (dto.menuId) {
      await this.prisma.orderMenu.create({
        data: {
          order_id: order.id,
          menu_id: dto.menuId,
          quantity: 1,
        },
      });
    }

    return order;
  }

  async update(id: number, dto: UpdateOrderDto, user: JwtPayload) {
    const order = await this.findById(id, user);
    if (!this.isEditable(order.status)) {
      throw new BadRequestException('Order cannot be modified');
    }

    return this.prisma.order.update({
      where: { id },
      data: {
        delivery_address: dto.deliveryAddress,
        delivery_hour: dto.deliveryHour,
        special_instructions: dto.specialInstructions,
      },
      include: this.getOrderIncludes(),
    });
  }

  async cancel(id: number, user: JwtPayload, reason: string) {
    const order = await this.findById(id, user);
    if (!this.isCancellable(order.status)) {
      throw new BadRequestException('Order cannot be cancelled');
    }

    return this.prisma.order.update({
      where: { id },
      data: { status: 'cancelled', cancellation_reason: reason },
    });
  }

  private ensureAccess(order: { user_id: number }, user: JwtPayload) {
    if (['admin', 'manager'].includes(user.role)) return;
    if (order.user_id !== user.sub) {
      throw new ForbiddenException('Access denied');
    }
  }

  private isEditable(status: string | null): boolean {
    return ['pending', 'confirmed'].includes(status ?? '');
  }

  private isCancellable(status: string | null): boolean {
    return ['pending', 'confirmed'].includes(status ?? '');
  }

  private generateOrderNumber(): string {
    const date = new Date().toISOString().slice(0, 10).replaceAll('-', '');
    const random = Math.random().toString(36).substring(2, 8).toUpperCase();
    return `VG-${date}-${random}`;
  }

  private getOrderIncludes() {
    return {
      User: { select: { email: true, first_name: true } },
      OrderMenu: true,
    };
  }
}
