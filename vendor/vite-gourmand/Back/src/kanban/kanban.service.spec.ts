import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { KanbanService } from './kanban.service';
import { PrismaService } from '../prisma';

describe('KanbanService', () => {
  let service: KanbanService;
  let prisma: jest.Mocked<PrismaService>;

  const mockColumn = {
    id: 1,
    name: 'Pending',
    mapped_status: 'pending',
    position: 1,
    color: '#FF9800',
    is_active: true,
    created_at: new Date(),
    created_by: null,
  };

  const mockTag = {
    id: 1,
    label: 'Urgent',
    color: '#F44336',
    created_at: new Date(),
    created_by: null,
  };

  const mockOrderTag = {
    id: 1,
    order_id: 1,
    tag_id: 1,
    OrderTag: mockTag,
  };

  beforeEach(async () => {
    const mockPrisma = {
      kanbanColumn: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
        aggregate: jest.fn(),
      },
      orderOrderTag: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        delete: jest.fn(),
      },
      orderTag: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
      order: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        update: jest.fn(),
      },
      $transaction: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        KanbanService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<KanbanService>(KanbanService);
    prisma = module.get(PrismaService);
  });

  describe('Columns', () => {
    describe('findAllColumns', () => {
      it('should return all columns ordered by position', async () => {
        (prisma.kanbanColumn.findMany as jest.Mock).mockResolvedValue([
          mockColumn,
        ]);

        const result = await service.findAllColumns();

        expect(result).toHaveLength(1);
        expect(prisma.kanbanColumn.findMany).toHaveBeenCalledWith({
          where: {},
          orderBy: { position: 'asc' },
        });
      });

      it('should filter by active only', async () => {
        (prisma.kanbanColumn.findMany as jest.Mock).mockResolvedValue([
          mockColumn,
        ]);

        await service.findAllColumns({ activeOnly: true });

        expect(prisma.kanbanColumn.findMany).toHaveBeenCalledWith({
          where: { is_active: true },
          orderBy: { position: 'asc' },
        });
      });
    });

    describe('findColumnById', () => {
      it('should return a column by id', async () => {
        (prisma.kanbanColumn.findUnique as jest.Mock).mockResolvedValue(
          mockColumn,
        );

        const result = await service.findColumnById(1);

        expect(result).toEqual(mockColumn);
      });

      it('should throw NotFoundException if not found', async () => {
        (prisma.kanbanColumn.findUnique as jest.Mock).mockResolvedValue(null);

        await expect(service.findColumnById(999)).rejects.toThrow(
          NotFoundException,
        );
      });
    });

    describe('createColumn', () => {
      it('should create a new column', async () => {
        const createDto = {
          name: 'In Progress',
          mappedStatus: 'in_progress',
          color: '#2196F3',
        };
        (prisma.kanbanColumn.aggregate as jest.Mock).mockResolvedValue({
          _max: { position: 1 },
        });
        (prisma.kanbanColumn.create as jest.Mock).mockResolvedValue({
          id: 2,
          ...createDto,
          mapped_status: createDto.mappedStatus,
          position: 2,
        });

        const result = await service.createColumn(createDto);

        expect(result.name).toBe('In Progress');
        expect(result.position).toBe(2);
      });
    });

    describe('updateColumn', () => {
      it('should update a column', async () => {
        (prisma.kanbanColumn.findUnique as jest.Mock).mockResolvedValue(
          mockColumn,
        );
        (prisma.kanbanColumn.update as jest.Mock).mockResolvedValue({
          ...mockColumn,
          name: 'Updated Name',
        });

        const result = await service.updateColumn(1, { name: 'Updated Name' });

        expect(result.name).toBe('Updated Name');
      });
    });

    describe('deleteColumn', () => {
      it('should delete a column', async () => {
        (prisma.kanbanColumn.findUnique as jest.Mock).mockResolvedValue(
          mockColumn,
        );
        (prisma.kanbanColumn.delete as jest.Mock).mockResolvedValue(mockColumn);

        const result = await service.deleteColumn(1);

        expect(result.message).toBe('Kanban column deleted successfully');
      });
    });

    describe('reorderColumns', () => {
      it('should reorder columns', async () => {
        (prisma.$transaction as jest.Mock).mockResolvedValue([]);
        (prisma.kanbanColumn.findMany as jest.Mock).mockResolvedValue([
          mockColumn,
        ]);

        await service.reorderColumns([2, 1]);

        expect(prisma.$transaction).toHaveBeenCalled();
      });
    });
  });

  describe('Tags', () => {
    describe('findAllTags', () => {
      it('should return all tags', async () => {
        (prisma.orderTag.findMany as jest.Mock).mockResolvedValue([mockTag]);

        const result = await service.findAllTags();

        expect(result).toHaveLength(1);
      });
    });

    describe('findTagById', () => {
      it('should return a tag by id', async () => {
        (prisma.orderTag.findUnique as jest.Mock).mockResolvedValue(mockTag);

        const result = await service.findTagById(1);

        expect(result).toEqual(mockTag);
      });

      it('should throw NotFoundException if not found', async () => {
        (prisma.orderTag.findUnique as jest.Mock).mockResolvedValue(null);

        await expect(service.findTagById(999)).rejects.toThrow(
          NotFoundException,
        );
      });
    });

    describe('createTag', () => {
      it('should create a new tag', async () => {
        const createDto = { label: 'VIP', color: '#9C27B0' };
        (prisma.orderTag.create as jest.Mock).mockResolvedValue({
          id: 2,
          ...createDto,
        });

        const result = await service.createTag(createDto);

        expect(result.label).toBe('VIP');
      });
    });

    describe('updateTag', () => {
      it('should update a tag', async () => {
        (prisma.orderTag.findUnique as jest.Mock).mockResolvedValue(mockTag);
        (prisma.orderTag.update as jest.Mock).mockResolvedValue({
          ...mockTag,
          color: '#E91E63',
        });

        const result = await service.updateTag(1, { color: '#E91E63' });

        expect(result.color).toBe('#E91E63');
      });
    });

    describe('deleteTag', () => {
      it('should delete a tag', async () => {
        (prisma.orderTag.findUnique as jest.Mock).mockResolvedValue(mockTag);
        (prisma.orderTag.delete as jest.Mock).mockResolvedValue(mockTag);

        const result = await service.deleteTag(1);

        expect(result.message).toBe('Order tag deleted successfully');
      });
    });
  });

  describe('Order Tags', () => {
    describe('getOrderTags', () => {
      it('should return tags for an order', async () => {
        (prisma.orderOrderTag.findMany as jest.Mock).mockResolvedValue([
          mockOrderTag,
        ]);

        const result = await service.getOrderTags(1);

        expect(result).toHaveLength(1);
        expect(result[0].OrderTag).toEqual(mockTag);
      });
    });

    describe('addTagToOrder', () => {
      it('should add a tag to an order', async () => {
        (prisma.orderOrderTag.create as jest.Mock).mockResolvedValue(
          mockOrderTag,
        );

        const result = await service.addTagToOrder(1, 1);

        expect(result.order_id).toBe(1);
        expect(result.tag_id).toBe(1);
      });
    });

    describe('removeTagFromOrder', () => {
      it('should remove a tag from an order', async () => {
        (prisma.orderOrderTag.delete as jest.Mock).mockResolvedValue(
          mockOrderTag,
        );

        const result = await service.removeTagFromOrder(1, 1);

        expect(result.message).toBe('Tag removed from order');
      });
    });
  });

  describe('Kanban Board', () => {
    describe('getKanbanBoard', () => {
      it('should return full kanban board with columns and orders', async () => {
        const columns = [
          { ...mockColumn, id: 1, name: 'Pending', mapped_status: 'pending' },
          {
            ...mockColumn,
            id: 2,
            name: 'In Progress',
            mapped_status: 'in_progress',
          },
        ];
        const orders = [
          { id: 1, status: 'pending', OrderOrderTag: [mockOrderTag] },
          { id: 2, status: 'in_progress', OrderOrderTag: [] },
        ];

        (prisma.kanbanColumn.findMany as jest.Mock).mockResolvedValue(columns);
        (prisma.order.findMany as jest.Mock).mockResolvedValue(orders);

        const result = await service.getKanbanBoard();

        expect(result).toHaveLength(2);
        expect(result[0].orders).toHaveLength(1);
        expect(result[1].orders).toHaveLength(1);
      });
    });
  });
});
