import { Test, TestingModule } from '@nestjs/testing';
import { PlaylistGateway } from './playlist.gateway';
import { PlaylistService } from './playlist.service';
import { Socket } from 'socket.io';

describe('PlaylistGateway', () => {
  let gateway: PlaylistGateway;
  let playlistService: jest.Mocked<PlaylistService>;

  const mockSocket = {
    id: 'socket-1',
    handshake: { auth: { token: 'test-token' } },
    join: jest.fn(),
    leave: jest.fn(),
    emit: jest.fn(),
    to: jest.fn().mockReturnThis(),
    broadcast: { to: jest.fn().mockReturnThis(), emit: jest.fn() },
  } as unknown as Socket;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        PlaylistGateway,
        {
          provide: PlaylistService,
          useValue: {
            addTrack: jest.fn(),
            removeTrack: jest.fn(),
            reorderTracks: jest.fn(),
            getPlaylist: jest.fn(),
          },
        },
      ],
    }).compile();

    gateway = module.get<PlaylistGateway>(PlaylistGateway);
    playlistService = module.get(PlaylistService);
  });

  it('should be defined', () => {
    expect(gateway).toBeDefined();
  });

  it('should handle track:add', async () => {
    const payload = {
      playlistId: 'playlist-1',
      track: { trackId: 'track-1', title: 'Test' },
    };
    playlistService.addTrack.mockResolvedValue({ tracks: [] } as any);

    await gateway.handleAddTrack(mockSocket, payload);

    expect(playlistService.addTrack).toHaveBeenCalled();
  });

  it('should handle track:remove', async () => {
    const payload = { playlistId: 'playlist-1', trackId: 'track-1' };
    playlistService.removeTrack.mockResolvedValue({ tracks: [] } as any);

    await gateway.handleRemoveTrack(mockSocket, payload);

    expect(playlistService.removeTrack).toHaveBeenCalled();
  });

  it('should handle track:reorder', async () => {
    const payload = {
      playlistId: 'playlist-1',
      fromIndex: 0,
      toIndex: 2,
    };
    playlistService.reorderTracks.mockResolvedValue({ tracks: [] } as any);

    await gateway.handleReorderTracks(mockSocket, payload);

    expect(playlistService.reorderTracks).toHaveBeenCalled();
  });

  it('should handle join:playlist room', async () => {
    const payload = { playlistId: 'playlist-1' };
    playlistService.getPlaylist.mockResolvedValue({ id: 'playlist-1' } as any);

    await gateway.handleJoinRoom(mockSocket, payload);

    expect(mockSocket.join).toHaveBeenCalledWith('playlist:playlist-1');
  });
});
