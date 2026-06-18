/**
 * Kanban Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { KanbanColumn, Order } from '../../generated/prisma/client.js';
import {
  CreateKanbanColumnDto,
  UpdateKanbanColumnDto,
  CreateOrderTagDto,
  UpdateOrderTagDto,
} from './dto/kanban.dto';

@Injectable()
export class KanbanService {
  constructor(private readonly prisma: PrismaService) {}

  // Kanban Columns
  async findAllColumns(options?: { activeOnly?: boolean }) {
    const where = options?.activeOnly ? { is_active: true } : {};
    return this.prisma.kanbanColumn.findMany({
      where,
      orderBy: { position: 'asc' },
    });
  }

  async findColumnById(id: number) {
    const column = await this.prisma.kanbanColumn.findUnique({ where: { id } });
    if (!column) throw new NotFoundException('Kanban column not found');
    return column;
  }

  async createColumn(dto: CreateKanbanColumnDto, userId?: number) {
    // Get max position
    const maxPos = await this.prisma.kanbanColumn.aggregate({
      _max: { position: true },
    });
    const position = dto.position ?? (maxPos._max.position || 0) + 1;

    return this.prisma.kanbanColumn.create({
      data: {
        name: dto.name,
        mapped_status: dto.mappedStatus,
        color: dto.color,
        position,
        created_by: userId,
      },
    });
  }

  async updateColumn(id: number, dto: UpdateKanbanColumnDto) {
    await this.findColumnById(id);
    return this.prisma.kanbanColumn.update({
      where: { id },
      data: {
        name: dto.name,
        mapped_status: dto.mappedStatus,
        color: dto.color,
        position: dto.position,
        is_active: dto.isActive,
      },
    });
  }

  async deleteColumn(id: number) {
    await this.findColumnById(id);
    await this.prisma.kanbanColumn.delete({ where: { id } });
    return { message: 'Kanban column deleted successfully' };
  }

  async reorderColumns(columnIds: number[]) {
    const updates = columnIds.map((id, index) =>
      this.prisma.kanbanColumn.update({
        where: { id },
        data: { position: index },
      }),
    );
    await this.prisma.$transaction(updates);
    return this.findAllColumns();
  }

  // Order Tags
  async findAllTags() {
    return this.prisma.orderTag.findMany({ orderBy: { label: 'asc' } });
  }

  async findTagById(id: number) {
    const tag = await this.prisma.orderTag.findUnique({ where: { id } });
    if (!tag) throw new NotFoundException('Order tag not found');
    return tag;
  }

  async createTag(dto: CreateOrderTagDto, userId?: number) {
    return this.prisma.orderTag.create({
      data: {
        label: dto.label,
        color: dto.color,
        created_by: userId,
      },
    });
  }

  async updateTag(id: number, dto: UpdateOrderTagDto) {
    await this.findTagById(id);
    return this.prisma.orderTag.update({
      where: { id },
      data: { label: dto.label, color: dto.color },
    });
  }

  async deleteTag(id: number) {
    await this.findTagById(id);
    await this.prisma.orderTag.delete({ where: { id } });
    return { message: 'Order tag deleted successfully' };
  }

  // Order-Tag associations
  async addTagToOrder(orderId: number, tagId: number) {
    return this.prisma.orderOrderTag.create({
      data: { order_id: orderId, tag_id: tagId },
    });
  }

  async removeTagFromOrder(orderId: number, tagId: number) {
    await this.prisma.orderOrderTag.delete({
      where: { order_id_tag_id: { order_id: orderId, tag_id: tagId } },
    });
    return { message: 'Tag removed from order' };
  }

  async getOrderTags(orderId: number) {
    return this.prisma.orderOrderTag.findMany({
      where: { order_id: orderId },
      include: { OrderTag: true },
    });
  }

  // Kanban board view
  async getKanbanBoard() {
    const columns = await this.findAllColumns({ activeOnly: true });

    // Get orders grouped by status
    const orders = await this.prisma.order.findMany({
      where: {
        status: {
          in: columns
            .map((c: KanbanColumn) => c.mapped_status)
            .filter(Boolean) as string[],
        },
      },
      include: {
        User: { select: { id: true, first_name: true, last_name: true } },
        OrderOrderTag: { include: { OrderTag: true } },
      },
      orderBy: { order_date: 'desc' },
    });

    return columns.map((column: KanbanColumn) => ({
      ...column,
      orders: orders.filter((o: Order) => o.status === column.mapped_status),
    }));
  }
}
