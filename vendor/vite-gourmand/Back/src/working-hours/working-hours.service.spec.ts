import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { WorkingHoursService } from './working-hours.service';
import { PrismaService } from '../prisma';

describe('WorkingHoursService', () => {
  let service: WorkingHoursService;
  let prisma: jest.Mocked<PrismaService>;

  const mockWorkingHours = [
    { day: 'Lundi', opening: '09:00', closing: '22:00' },
    { day: 'Mardi', opening: '09:00', closing: '22:00' },
    { day: 'Mercredi', opening: '09:00', closing: '22:00' },
  ];

  beforeEach(async () => {
    const mockPrisma = {
      workingHours: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        update: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        WorkingHoursService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<WorkingHoursService>(WorkingHoursService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return all working hours sorted by day order', async () => {
      (prisma.workingHours.findMany as jest.Mock).mockResolvedValue(
        mockWorkingHours,
      );

      const result = await service.findAll();

      expect(result).toHaveLength(3);
      expect(prisma.workingHours.findMany).toHaveBeenCalled();
    });

    it('should sort days in correct order', async () => {
      const unsortedHours = [
        { day: 'Dimanche', opening: '10:00', closing: '20:00' },
        { day: 'Lundi', opening: '09:00', closing: '22:00' },
      ];
      (prisma.workingHours.findMany as jest.Mock).mockResolvedValue(
        unsortedHours,
      );

      const result = await service.findAll();

      expect(result[0].day).toBe('Lundi');
      expect(result[1].day).toBe('Dimanche');
    });
  });

  describe('update', () => {
    it('should update working hours for a day', async () => {
      const dto = { opening: '10:00', closing: '21:00' };
      (prisma.workingHours.findUnique as jest.Mock).mockResolvedValue(
        mockWorkingHours[0],
      );
      (prisma.workingHours.update as jest.Mock).mockResolvedValue({
        day: 'Lundi',
        ...dto,
      });

      const result = await service.update('Lundi', dto);

      expect(result.opening).toBe('10:00');
      expect(prisma.workingHours.update).toHaveBeenCalledWith({
        where: { day: 'Lundi' },
        data: dto,
      });
    });

    it('should throw NotFoundException if day not found', async () => {
      (prisma.workingHours.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(
        service.update('InvalidDay', { opening: '10:00', closing: '20:00' }),
      ).rejects.toThrow(NotFoundException);
    });

    it('should update only opening time', async () => {
      (prisma.workingHours.findUnique as jest.Mock).mockResolvedValue(
        mockWorkingHours[0],
      );
      (prisma.workingHours.update as jest.Mock).mockResolvedValue({
        day: 'Lundi',
        opening: '08:00',
        closing: '22:00',
      });

      const result = await service.update('Lundi', {
        opening: '08:00',
        closing: '22:00',
      });

      expect(result.opening).toBe('08:00');
    });

    it('should update only closing time', async () => {
      (prisma.workingHours.findUnique as jest.Mock).mockResolvedValue(
        mockWorkingHours[0],
      );
      (prisma.workingHours.update as jest.Mock).mockResolvedValue({
        day: 'Lundi',
        opening: '09:00',
        closing: '23:00',
      });

      const result = await service.update('Lundi', {
        opening: '09:00',
        closing: '23:00',
      });

      expect(result.closing).toBe('23:00');
    });
  });
});
