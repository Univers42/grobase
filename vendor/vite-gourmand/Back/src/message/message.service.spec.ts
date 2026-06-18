import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException, ForbiddenException } from '@nestjs/common';
import { MessageService } from './message.service';
import { PrismaService } from '../prisma';

describe('MessageService', () => {
  let service: MessageService;
  let prisma: jest.Mocked<PrismaService>;

  const mockMessage = {
    id: 1,
    sender_id: 1,
    recipient_id: 2,
    subject: 'Test Subject',
    body: 'Test message content',
    is_read: false,
    parent_id: null,
    priority: 'normal',
    sent_at: new Date(),
    read_at: null,
    User_Message_sender_idToUser: {
      id: 1,
      first_name: 'John',
      last_name: 'Doe',
      email: 'john@example.com',
    },
    User_Message_recipient_idToUser: {
      id: 2,
      first_name: 'Jane',
      last_name: 'Smith',
      email: 'jane@example.com',
    },
    other_Message: [],
  };

  beforeEach(async () => {
    const mockPrisma = {
      message: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        MessageService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<MessageService>(MessageService);
    prisma = module.get(PrismaService);
  });

  describe('getInbox', () => {
    it('should return inbox messages', async () => {
      (prisma.message.findMany as jest.Mock).mockResolvedValue([mockMessage]);

      const result = await service.getInbox(2);

      expect(result).toHaveLength(1);
      expect(prisma.message.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ recipient_id: 2 }),
        }),
      );
    });

    it('should filter by unread only', async () => {
      (prisma.message.findMany as jest.Mock).mockResolvedValue([mockMessage]);

      await service.getInbox(2, { unreadOnly: true });

      expect(prisma.message.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ recipient_id: 2, is_read: false }),
        }),
      );
    });

    it('should respect limit and offset', async () => {
      (prisma.message.findMany as jest.Mock).mockResolvedValue([mockMessage]);

      await service.getInbox(2, { limit: 10, offset: 5 });

      expect(prisma.message.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          take: 10,
          skip: 5,
        }),
      );
    });
  });

  describe('getSent', () => {
    it('should return sent messages', async () => {
      (prisma.message.findMany as jest.Mock).mockResolvedValue([mockMessage]);

      const result = await service.getSent(1);

      expect(result).toHaveLength(1);
      expect(prisma.message.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ sender_id: 1 }),
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return a message by id', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);

      const result = await service.findById(1, 1);

      expect(result).toEqual(mockMessage);
    });

    it('should throw NotFoundException if message not found', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999, 1)).rejects.toThrow(NotFoundException);
    });

    it('should throw ForbiddenException if user not sender or recipient', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);

      await expect(service.findById(1, 3)).rejects.toThrow(ForbiddenException);
    });
  });

  describe('send', () => {
    it('should send a new message', async () => {
      const sendDto = {
        recipientId: 2,
        subject: 'New Subject',
        body: 'New content',
      };
      (prisma.message.create as jest.Mock).mockResolvedValue({
        id: 2,
        sender_id: 1,
        recipient_id: 2,
        subject: sendDto.subject,
        body: sendDto.body,
        is_read: false,
      });

      const result = await service.send(1, sendDto);

      expect(result.subject).toBe('New Subject');
      expect(result.sender_id).toBe(1);
      expect(result.recipient_id).toBe(2);
    });
  });

  describe('reply', () => {
    it('should reply to an existing message', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);
      (prisma.message.create as jest.Mock).mockResolvedValue({
        id: 3,
        sender_id: 2,
        recipient_id: 1,
        subject: 'Re: Test Subject',
        body: 'Reply content',
        parent_id: 1,
        is_read: false,
      });

      const result = await service.reply(2, 1, { body: 'Reply content' });

      expect(result.parent_id).toBe(1);
      expect(result.subject).toBe('Re: Test Subject');
    });

    it('should throw ForbiddenException if user is not participant', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);

      await expect(
        service.reply(3, 1, { body: 'Reply content' }),
      ).rejects.toThrow(ForbiddenException);
    });
  });

  describe('markAsRead', () => {
    it('should mark message as read', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);
      (prisma.message.update as jest.Mock).mockResolvedValue({
        ...mockMessage,
        is_read: true,
        read_at: new Date(),
      });

      const result = await service.markAsRead(1, 2);

      expect(result.is_read).toBe(true);
    });

    it('should throw ForbiddenException if not recipient', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);

      await expect(service.markAsRead(1, 1)).rejects.toThrow(
        ForbiddenException,
      );
    });
  });

  describe('delete', () => {
    it('should delete a message', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);
      (prisma.message.delete as jest.Mock).mockResolvedValue(mockMessage);

      const result = await service.delete(1, 1);

      expect(result.message).toBe('Message deleted successfully');
    });

    it('should throw ForbiddenException if user not sender or recipient', async () => {
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);

      await expect(service.delete(1, 3)).rejects.toThrow(ForbiddenException);
    });
  });

  describe('getThread', () => {
    it('should return message thread', async () => {
      const thread = [mockMessage, { ...mockMessage, id: 2, parent_id: 1 }];
      (prisma.message.findUnique as jest.Mock).mockResolvedValue(mockMessage);
      (prisma.message.findMany as jest.Mock).mockResolvedValue(thread);

      const result = await service.getThread(1, 1);

      expect(result).toHaveLength(2);
    });
  });

  describe('getUnreadCount', () => {
    it('should return unread count', async () => {
      (prisma.message.count as jest.Mock).mockResolvedValue(5);

      const result = await service.getUnreadCount(2);

      expect(result).toBe(5);
      expect(prisma.message.count).toHaveBeenCalledWith({
        where: { recipient_id: 2, is_read: false },
      });
    });
  });
});
