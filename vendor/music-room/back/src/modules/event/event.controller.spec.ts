import { Test, TestingModule } from '@nestjs/testing';
import { EventController } from './event.controller';
import { EventService } from './event.service';

describe('EventController', () => {
  let controller: EventController;
  let eventService: jest.Mocked<Partial<EventService>>;

  beforeEach(async () => {
    eventService = {
      create: jest.fn(),
      findAll: jest.fn(),
      findById: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
      joinEvent: jest.fn(),
      leaveEvent: jest.fn(),
      suggestTrack: jest.fn(),
      voteForTrack: jest.fn(),
      removeVote: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [EventController],
      providers: [{ provide: EventService, useValue: eventService }],
    }).compile();

    controller = module.get<EventController>(EventController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('create', () => {
    it('should create an event with the current user', async () => {
      const dto = { name: 'Test Event', licenseType: 'OPEN' };
      const user = { _id: 'user1' };
      const event = { _id: 'ev1', ...dto };
      eventService.create.mockResolvedValue(event as any);

      const result = await controller.create(user as any, dto as any);

      expect(eventService.create).toHaveBeenCalledWith(dto, 'user1');
      expect(result).toEqual(event);
    });
  });

  describe('findAll', () => {
    it('should return list of events', async () => {
      const events = [{ _id: 'ev1' }, { _id: 'ev2' }];
      eventService.findAll.mockResolvedValue(events as any);

      const result = await controller.findAll();

      expect(eventService.findAll).toHaveBeenCalled();
      expect(result).toHaveLength(2);
    });
  });

  describe('findById', () => {
    it('should return single event', async () => {
      const event = { _id: 'ev1', name: 'Party' };
      eventService.findById.mockResolvedValue(event as any);

      const result = await controller.findById('ev1');

      expect(eventService.findById).toHaveBeenCalledWith('ev1');
      expect(result).toEqual(event);
    });
  });

  describe('joinEvent', () => {
    it('should join event with user id', async () => {
      const user = { _id: 'user1' };
      eventService.joinEvent.mockResolvedValue({} as any);

      await controller.joinEvent('ev1', user as any);

      expect(eventService.joinEvent).toHaveBeenCalledWith('ev1', 'user1');
    });
  });

  describe('suggestTrack', () => {
    it('should suggest track to event', async () => {
      const dto = { deezerTrackId: '12345', title: 'Song', artist: 'Artist' };
      const user = { _id: 'user1' };
      eventService.suggestTrack.mockResolvedValue({} as any);

      await controller.suggestTrack('ev1', user as any, dto as any);

      expect(eventService.suggestTrack).toHaveBeenCalledWith('ev1', dto, 'user1');
    });
  });

  describe('delete', () => {
    it('should delete event by owner', async () => {
      const user = { _id: 'user1' };
      eventService.delete.mockResolvedValue(undefined);

      await controller.delete('ev1', user as any);

      expect(eventService.delete).toHaveBeenCalledWith('ev1', 'user1');
    });
  });
});
