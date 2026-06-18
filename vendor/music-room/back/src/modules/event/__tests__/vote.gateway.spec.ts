import { Test, TestingModule } from '@nestjs/testing';
import { VoteGateway } from './vote.gateway';
import { EventService } from './event.service';
import { Socket } from 'socket.io';

describe('VoteGateway', () => {
  let gateway: VoteGateway;
  let eventService: jest.Mocked<EventService>;

  const mockSocket = {
    id: 'socket-1',
    handshake: { auth: { token: 'test-token' } },
    join: jest.fn(),
    leave: jest.fn(),
    emit: jest.fn(),
    to: jest.fn().mockReturnThis(),
  } as unknown as Socket;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        VoteGateway,
        {
          provide: EventService,
          useValue: {
            vote: jest.fn(),
            getEvent: jest.fn(),
            getTrackVotes: jest.fn(),
          },
        },
      ],
    }).compile();

    gateway = module.get<VoteGateway>(VoteGateway);
    eventService = module.get(EventService);
  });

  it('should be defined', () => {
    expect(gateway).toBeDefined();
  });

  it('should handle vote:up', async () => {
    const payload = { eventId: 'event-1', trackId: 'track-1' };
    eventService.vote.mockResolvedValue({ votes: 5 } as any);

    const result = await gateway.handleVote(mockSocket, {
      ...payload,
      direction: 'up',
    });

    expect(eventService.vote).toHaveBeenCalledWith(
      expect.any(String),
      payload.eventId,
      payload.trackId,
      'up',
    );
    expect(result).toEqual({ votes: 5 });
  });

  it('should handle vote:down', async () => {
    const payload = { eventId: 'event-1', trackId: 'track-1' };
    eventService.vote.mockResolvedValue({ votes: 3 } as any);

    const result = await gateway.handleVote(mockSocket, {
      ...payload,
      direction: 'down',
    });

    expect(eventService.vote).toHaveBeenCalledWith(
      expect.any(String),
      payload.eventId,
      payload.trackId,
      'down',
    );
    expect(result).toEqual({ votes: 3 });
  });

  it('should handle join:event room', async () => {
    const payload = { eventId: 'event-1' };
    eventService.getEvent.mockResolvedValue({ id: 'event-1' } as any);

    await gateway.handleJoinRoom(mockSocket, payload);

    expect(mockSocket.join).toHaveBeenCalledWith('event:event-1');
  });

  it('should handle leave:event room', async () => {
    const payload = { eventId: 'event-1' };

    await gateway.handleLeaveRoom(mockSocket, payload);

    expect(mockSocket.leave).toHaveBeenCalledWith('event:event-1');
  });
});
