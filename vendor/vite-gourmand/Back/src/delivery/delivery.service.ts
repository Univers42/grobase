/**
 * Delivery Service
 */
import {
  Injectable,
  NotFoundException,
  BadRequestException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import type { Prisma } from '../../generated/prisma/client.js';
import {
  CreateDeliveryAssignmentDto,
  UpdateDeliveryAssignmentDto,
  RateDeliveryDto,
  DeliveryStatus,
} from './dto/delivery.dto';

@Injectable()
export class DeliveryService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(options?: { status?: string; deliveryPersonId?: number }) {
    const where: Prisma.DeliveryAssignmentWhereInput = {};
    if (options?.status) where.status = options.status;
    if (options?.deliveryPersonId)
      where.delivery_person_id = options.deliveryPersonId;

    return this.prisma.deliveryAssignment.findMany({
      where,
      include: {
        Order: {
          select: {
            id: true,
            order_number: true,
            delivery_address: true,
            delivery_city: true,
            delivery_date: true,
            delivery_hour: true,
          },
        },
        User: {
          select: {
            id: true,
            first_name: true,
            last_name: true,
            phone_number: true,
          },
        },
      },
      orderBy: { assigned_at: 'desc' },
    });
  }

  async findById(id: number) {
    const delivery = await this.prisma.deliveryAssignment.findUnique({
      where: { id },
      include: {
        Order: true,
        User: {
          select: {
            id: true,
            first_name: true,
            last_name: true,
            phone_number: true,
            email: true,
          },
        },
      },
    });
    if (!delivery) throw new NotFoundException('Delivery assignment not found');
    return delivery;
  }

  async findByOrderId(orderId: number) {
    return this.prisma.deliveryAssignment.findFirst({
      where: { order_id: orderId },
      include: {
        User: {
          select: {
            id: true,
            first_name: true,
            last_name: true,
            phone_number: true,
          },
        },
      },
    });
  }

  async create(dto: CreateDeliveryAssignmentDto) {
    // Check if order exists
    const order = await this.prisma.order.findUnique({
      where: { id: dto.orderId },
    });
    if (!order) throw new NotFoundException('Order not found');

    // Check if assignment already exists
    const existing = await this.findByOrderId(dto.orderId);
    if (existing)
      throw new BadRequestException(
        'Delivery assignment already exists for this order',
      );

    return this.prisma.deliveryAssignment.create({
      data: {
        order_id: dto.orderId,
        delivery_person_id: dto.deliveryPersonId,
        vehicle_type: dto.vehicleType,
        delivery_notes: dto.deliveryNotes,
        status: 'assigned',
      },
      include: {
        Order: {
          select: { id: true, order_number: true, delivery_address: true },
        },
        User: { select: { id: true, first_name: true, last_name: true } },
      },
    });
  }

  async update(id: number, dto: UpdateDeliveryAssignmentDto) {
    await this.findById(id);

    const data: Prisma.DeliveryAssignmentUncheckedUpdateInput = {};
    if (dto.deliveryPersonId !== undefined)
      data.delivery_person_id = dto.deliveryPersonId;
    if (dto.vehicleType !== undefined) data.vehicle_type = dto.vehicleType;
    if (dto.status !== undefined) data.status = dto.status;
    if (dto.deliveryNotes !== undefined)
      data.delivery_notes = dto.deliveryNotes;
    if (dto.proofPhotoUrl !== undefined)
      data.proof_photo_url = dto.proofPhotoUrl;

    // Update timestamps based on status
    if (dto.status === DeliveryStatus.PICKED_UP) data.picked_up_at = new Date();
    if (dto.status === DeliveryStatus.DELIVERED) data.delivered_at = new Date();

    return this.prisma.deliveryAssignment.update({
      where: { id },
      data,
      include: {
        Order: { select: { id: true, order_number: true } },
        User: { select: { id: true, first_name: true, last_name: true } },
      },
    });
  }

  async delete(id: number) {
    await this.findById(id);
    await this.prisma.deliveryAssignment.delete({ where: { id } });
    return { message: 'Delivery assignment deleted successfully' };
  }

  async markPickedUp(id: number) {
    return this.update(id, { status: DeliveryStatus.PICKED_UP });
  }

  async markDelivered(id: number, proofPhotoUrl?: string) {
    return this.update(id, { status: DeliveryStatus.DELIVERED, proofPhotoUrl });
  }

  async rateDelivery(id: number, dto: RateDeliveryDto) {
    await this.findById(id);
    return this.prisma.deliveryAssignment.update({
      where: { id },
      data: { client_rating: dto.rating },
    });
  }

  async getMyDeliveries(deliveryPersonId: number) {
    return this.findAll({ deliveryPersonId });
  }

  async getPendingDeliveries() {
    return this.findAll({ status: 'assigned' });
  }
}
