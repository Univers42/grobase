import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ContactService } from './contact.service';
import { PrismaService } from '../prisma';
import { MailService } from '../mail/mail.service';

describe('ContactService', () => {
  let service: ContactService;
  let prisma: jest.Mocked<PrismaService>;

  const mockContactMessage = {
    id: 1,
    title: 'Test Subject',
    description: 'Test message content',
    email: 'test@example.com',
    created_at: new Date(),
  };

  beforeEach(async () => {
    const mockPrisma = {
      contactMessage: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        delete: jest.fn(),
      },
      supportTicket: {
        create: jest
          .fn()
          .mockResolvedValue({ id: 1, ticket_number: 'TK202602-ABC123' }),
      },
    };

    const mockMailService = {
      send: jest.fn().mockResolvedValue(undefined),
      sendContactConfirmation: jest.fn().mockResolvedValue(undefined),
      sendOwnerNotification: jest.fn().mockResolvedValue(undefined),
    };

    const mockConfigService = {
      get: jest.fn().mockReturnValue('test@example.com'),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ContactService,
        { provide: PrismaService, useValue: mockPrisma },
        { provide: MailService, useValue: mockMailService },
        { provide: ConfigService, useValue: mockConfigService },
      ],
    }).compile();

    service = module.get<ContactService>(ContactService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return contact messages', async () => {
      (prisma.contactMessage.findMany as jest.Mock).mockResolvedValue([
        mockContactMessage,
      ]);

      const result = await service.findAll();

      expect(result).toHaveLength(1);
    });

    it('should support limit and offset', async () => {
      (prisma.contactMessage.findMany as jest.Mock).mockResolvedValue([
        mockContactMessage,
      ]);

      await service.findAll({ limit: 10, offset: 5 });

      expect(prisma.contactMessage.findMany).toHaveBeenCalledWith({
        orderBy: { created_at: 'desc' },
        take: 10,
        skip: 5,
      });
    });
  });

  describe('findById', () => {
    it('should return a contact message by id', async () => {
      (prisma.contactMessage.findUnique as jest.Mock).mockResolvedValue(
        mockContactMessage,
      );

      const result = await service.findById(1);

      expect(result).toEqual(mockContactMessage);
      expect(prisma.contactMessage.findUnique).toHaveBeenCalledWith({
        where: { id: 1 },
      });
    });

    it('should throw NotFoundException if message not found', async () => {
      (prisma.contactMessage.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a contact message', async () => {
      const createDto = {
        name: 'New User',
        title: 'New Subject',
        description: 'New message',
        email: 'new@example.com',
      };
      (prisma.contactMessage.create as jest.Mock).mockResolvedValue({
        id: 2,
        ...createDto,
        created_at: new Date(),
      });

      const result = await service.create(createDto);

      expect(result.title).toBe(createDto.title);
    });
  });

  describe('delete', () => {
    it('should delete a contact message', async () => {
      (prisma.contactMessage.findUnique as jest.Mock).mockResolvedValue(
        mockContactMessage,
      );
      (prisma.contactMessage.delete as jest.Mock).mockResolvedValue(
        mockContactMessage,
      );

      const result = await service.delete(1);

      expect(result.message).toBe('Contact message deleted successfully');
      expect(prisma.contactMessage.delete).toHaveBeenCalledWith({
        where: { id: 1 },
      });
    });

    it('should throw NotFoundException if message not found', async () => {
      (prisma.contactMessage.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('count', () => {
    it('should return total count of messages', async () => {
      (prisma.contactMessage.count as jest.Mock).mockResolvedValue(5);

      const result = await service.count();

      expect(result).toBe(5);
    });
  });
});
