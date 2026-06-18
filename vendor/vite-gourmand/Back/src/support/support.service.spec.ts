import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { SupportService } from './support.service';
import { PrismaService } from '../prisma';
import {
  TicketCategory,
  TicketPriority,
  TicketStatus,
} from './dto/support.dto';

describe('SupportService', () => {
  let service: SupportService;
  let prisma: jest.Mocked<PrismaService>;

  const mockTicket = {
    id: 1,
    ticket_number: 'TK202401-ABC123',
    created_by: 1,
    subject: 'Test Support Ticket',
    description: 'I have an issue with my order',
    category: 'order',
    priority: 'normal',
    status: 'open',
    assigned_to: null,
    created_at: new Date(),
    updated_at: new Date(),
    resolved_at: null,
    closed_at: null,
    User_SupportTicket_created_byToUser: {
      id: 1,
      first_name: 'John',
      last_name: 'Doe',
      email: 'john@example.com',
    },
    User_SupportTicket_assigned_toToUser: null,
    TicketMessage: [],
  };

  const mockTicketMessage = {
    id: 1,
    ticket_id: 1,
    user_id: 1,
    body: 'Additional details about the issue',
    is_internal: false,
    created_at: new Date(),
    User: {
      id: 1,
      first_name: 'John',
      last_name: 'Doe',
    },
  };

  beforeEach(async () => {
    const mockPrisma = {
      supportTicket: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
      ticketMessage: {
        findMany: jest.fn(),
        create: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        SupportService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<SupportService>(SupportService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return tickets', async () => {
      (prisma.supportTicket.findMany as jest.Mock).mockResolvedValue([
        mockTicket,
      ]);

      const result = await service.findAll();

      expect(result).toHaveLength(1);
    });

    it('should filter by status', async () => {
      (prisma.supportTicket.findMany as jest.Mock).mockResolvedValue([
        mockTicket,
      ]);

      await service.findAll({ status: 'open' });

      expect(prisma.supportTicket.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'open' }),
        }),
      );
    });

    it('should filter by assignedTo', async () => {
      (prisma.supportTicket.findMany as jest.Mock).mockResolvedValue([
        mockTicket,
      ]);

      await service.findAll({ assignedTo: 3 });

      expect(prisma.supportTicket.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ assigned_to: 3 }),
        }),
      );
    });
  });

  describe('getMyTickets', () => {
    it('should return user tickets', async () => {
      (prisma.supportTicket.findMany as jest.Mock).mockResolvedValue([
        mockTicket,
      ]);

      const result = await service.getMyTickets(1);

      expect(result).toHaveLength(1);
    });
  });

  describe('findById', () => {
    it('should return a ticket by id', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(
        mockTicket,
      );

      const result = await service.findById(1);

      expect(result).toEqual(mockTicket);
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('findByTicketNumber', () => {
    it('should return a ticket by ticket number', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(
        mockTicket,
      );

      const result = await service.findByTicketNumber('TK202401-ABC123');

      expect(result).toEqual(mockTicket);
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findByTicketNumber('INVALID')).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('create', () => {
    it('should create a new ticket', async () => {
      const createDto = {
        subject: 'New Issue',
        description: 'Description of the issue',
        category: TicketCategory.ORDER,
        priority: TicketPriority.LOW,
      };
      (prisma.supportTicket.create as jest.Mock).mockResolvedValue({
        id: 2,
        created_by: 1,
        ticket_number: 'TK202401-XYZ789',
        ...createDto,
        status: 'open',
      });

      const result = await service.create(1, createDto);

      expect(result.subject).toBe('New Issue');
      expect(result.status).toBe('open');
    });
  });

  describe('addMessage', () => {
    it('should add a message to a ticket', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(
        mockTicket,
      );
      (prisma.ticketMessage.create as jest.Mock).mockResolvedValue(
        mockTicketMessage,
      );

      const result = await service.addMessage(1, 1, {
        body: 'Additional details',
      });

      expect(result.body).toBe('Additional details about the issue');
    });
  });

  describe('update', () => {
    it('should update ticket status', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(
        mockTicket,
      );
      (prisma.supportTicket.update as jest.Mock).mockResolvedValue({
        ...mockTicket,
        status: 'in_progress',
      });

      const result = await service.update(1, {
        status: TicketStatus.IN_PROGRESS,
      });

      expect(result.status).toBe('in_progress');
    });

    it('should set resolved_at when status is resolved', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(
        mockTicket,
      );
      (prisma.supportTicket.update as jest.Mock).mockResolvedValue({
        ...mockTicket,
        status: 'resolved',
        resolved_at: new Date(),
      });

      const result = await service.update(1, { status: TicketStatus.RESOLVED });

      expect(result.status).toBe('resolved');
      expect(result.resolved_at).toBeDefined();
    });
  });

  describe('assignTicket', () => {
    it('should assign ticket to staff member', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(
        mockTicket,
      );
      (prisma.supportTicket.update as jest.Mock).mockResolvedValue({
        ...mockTicket,
        assigned_to: 3,
        status: 'in_progress',
      });

      const result = await service.assignTicket(1, 3);

      expect(result.assigned_to).toBe(3);
      expect(result.status).toBe('in_progress');
    });
  });

  describe('resolveTicket', () => {
    it('should resolve a ticket', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue(
        mockTicket,
      );
      (prisma.supportTicket.update as jest.Mock).mockResolvedValue({
        ...mockTicket,
        status: 'resolved',
        resolved_at: new Date(),
      });

      const result = await service.resolveTicket(1);

      expect(result.status).toBe('resolved');
    });
  });

  describe('closeTicket', () => {
    it('should close a ticket', async () => {
      (prisma.supportTicket.findUnique as jest.Mock).mockResolvedValue({
        ...mockTicket,
        status: 'resolved',
      });
      (prisma.supportTicket.update as jest.Mock).mockResolvedValue({
        ...mockTicket,
        status: 'closed',
        closed_at: new Date(),
      });

      const result = await service.closeTicket(1);

      expect(result.status).toBe('closed');
    });
  });

  describe('getStats', () => {
    it('should return ticket statistics', async () => {
      (prisma.supportTicket.count as jest.Mock)
        .mockResolvedValueOnce(5) // open
        .mockResolvedValueOnce(2) // in_progress
        .mockResolvedValueOnce(3) // resolved
        .mockResolvedValueOnce(10); // closed

      const result = await service.getStats();

      expect(result.open).toBe(5);
      expect(result.inProgress).toBe(2);
      expect(result.resolved).toBe(3);
      expect(result.closed).toBe(10);
      expect(result.total).toBe(20);
    });
  });

  describe('getAssignedTickets', () => {
    it('should return tickets assigned to staff member', async () => {
      (prisma.supportTicket.findMany as jest.Mock).mockResolvedValue([
        { ...mockTicket, assigned_to: 3 },
      ]);

      const result = await service.getAssignedTickets(3);

      expect(result).toHaveLength(1);
    });
  });

  describe('getOpenTickets', () => {
    it('should return open tickets', async () => {
      (prisma.supportTicket.findMany as jest.Mock).mockResolvedValue([
        mockTicket,
      ]);

      const result = await service.getOpenTickets();

      expect(result).toHaveLength(1);
    });
  });
});
