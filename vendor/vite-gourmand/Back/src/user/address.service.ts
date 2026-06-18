/**
 * Address Service
 * User address management
 */
import {
  Injectable,
  NotFoundException,
  ForbiddenException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateAddressDto, UpdateAddressDto } from './dto/address.dto';

@Injectable()
export class AddressService {
  constructor(private readonly prisma: PrismaService) {}

  async findByUser(userId: number) {
    return this.prisma.userAddress.findMany({
      where: { user_id: userId },
      orderBy: { is_default: 'desc' },
    });
  }

  async create(userId: number, dto: CreateAddressDto) {
    if (dto.isDefault) {
      await this.clearDefaultAddresses(userId);
    }
    return this.prisma.userAddress.create({
      data: {
        user_id: userId,
        label: dto.label,
        street_address: dto.streetAddress,
        city: dto.city,
        postal_code: dto.postalCode,
        country: dto.country ?? 'France',
        is_default: dto.isDefault ?? false,
      },
    });
  }

  async update(userId: number, id: number, dto: UpdateAddressDto) {
    await this.ensureOwnership(userId, id);
    if (dto.isDefault) {
      await this.clearDefaultAddresses(userId);
    }
    return this.prisma.userAddress.update({
      where: { id },
      data: {
        label: dto.label,
        street_address: dto.streetAddress,
        city: dto.city,
        postal_code: dto.postalCode,
        is_default: dto.isDefault,
      },
    });
  }

  async delete(userId: number, id: number) {
    await this.ensureOwnership(userId, id);
    await this.prisma.userAddress.delete({ where: { id } });
    return { message: 'Address deleted successfully' };
  }

  private async ensureOwnership(userId: number, addressId: number) {
    const address = await this.prisma.userAddress.findUnique({
      where: { id: addressId },
    });
    if (!address) throw new NotFoundException('Address not found');
    if (address.user_id !== userId) {
      throw new ForbiddenException('Not your address');
    }
  }

  private async clearDefaultAddresses(userId: number) {
    await this.prisma.userAddress.updateMany({
      where: { user_id: userId, is_default: true },
      data: { is_default: false },
    });
  }
}
