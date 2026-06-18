/**
 * Working Hours Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { UpdateWorkingHoursDto } from './dto/working-hours.dto';

const DAY_ORDER = [
  'Lundi',
  'Mardi',
  'Mercredi',
  'Jeudi',
  'Vendredi',
  'Samedi',
  'Dimanche',
];

@Injectable()
export class WorkingHoursService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll() {
    const hours = await this.prisma.workingHours.findMany();
    return this.sortByDayOrder(hours);
  }

  async update(day: string, dto: UpdateWorkingHoursDto) {
    const existing = await this.prisma.workingHours.findUnique({
      where: { day },
    });

    if (!existing)
      throw new NotFoundException(`Working hours for ${day} not found`);

    return this.prisma.workingHours.update({
      where: { day },
      data: { opening: dto.opening, closing: dto.closing },
    });
  }

  private sortByDayOrder(hours: { day: string }[]) {
    return hours.sort(
      (a, b) => DAY_ORDER.indexOf(a.day) - DAY_ORDER.indexOf(b.day),
    );
  }
}
