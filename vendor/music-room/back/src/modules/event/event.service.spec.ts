import { Test, TestingModule } from '@nestjs/testing';
import { EventService } from './event.service';
import { getModelToken } from '@nestjs/mongoose';
import { NotFoundException, ForbiddenException } from '@nestjs/common';

describe('EventService', () => {
  let service: EventService;
  let mockEventModel: any;

  const mockEvent = {
    _id: 'event123',
    name: 'Test Event',
    description: 'A test event',
    creator: 'user123',
    visibility: 'public',
    licenseType: 'open',
    playlist: [],
    invitedUsers: [],
    status: 'upcoming',
    save: jest.fn().mockResolvedValue(true),
    toObject: jest.fn().mockReturnThis(),
  };

  beforeEach(async () => {
    const ModelConstructor: any = jest.fn().mockImplementation((data) => ({
      ...data,
      _id: 'newEvent123',
      save: jest.fn().mockResolvedValue({ _id: 'newEvent123', ...data }),
    }));

    ModelConstructor.find = jest.fn();
    ModelConstructor.findById = jest.fn();
    ModelConstructor.findByIdAndUpdate = jest.fn();
    ModelConstructor.findByIdAndDelete = jest.fn();

    mockEventModel = ModelConstructor;

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        EventService,
        { provide: getModelToken('Event'), useValue: ModelConstructor },
      ],
    }).compile();

    service = module.get<EventService>(EventService);
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  describe('create', () => {
    it('should create an event with correct data', async () => {
      const dto = {
        name: 'New Event',
        description: 'Description',
        visibility: 'public' as const,
        licenseType: 'open' as const,
      };

      const result = await service.create(dto, 'user123');
      expect(result).toBeDefined();
      expect(result.name).toBe('New Event');
    });
  });

  describe('findById', () => {
    it('should throw NotFoundException when event not found', async () => {
      mockEventModel.findById.mockReturnValue({
        populate: jest.fn().mockResolvedValue(null),
      });

      await expect(service.findById('nonexistent')).rejects.toThrow(NotFoundException);
    });

    it('should return event when found', async () => {
      mockEventModel.findById.mockReturnValue({
        populate: jest.fn().mockResolvedValue(mockEvent),
      });

      const result = await service.findById('event123');
      expect(result).toEqual(mockEvent);
    });
  });

  describe('suggestTrack', () => {
    it('should throw NotFoundException when event not found', async () => {
      mockEventModel.findById.mockResolvedValue(null);

      await expect(
        service.suggestTrack('nonexistent', {
          trackId: 'track1',
          title: 'Track',
          artist: 'Artist',
        }, 'user123'),
      ).rejects.toThrow(NotFoundException);
    });
  });

  describe('voteForTrack', () => {
    it('should throw NotFoundException when event not found', async () => {
      mockEventModel.findOneAndUpdate.mockResolvedValue(null);

      await expect(
        service.voteForTrack('nonexistent', 'track1', 'user123'),
      ).rejects.toThrow();
    });
  });

  describe('delete', () => {
    it('should throw ForbiddenException when non-owner tries to delete', async () => {
      mockEventModel.findById.mockResolvedValue({
        ...mockEvent,
        creator: { toString: () => 'otherUser' },
      });

      await expect(
        service.delete('event123', 'user123'),
      ).rejects.toThrow(ForbiddenException);
    });
  });
});
