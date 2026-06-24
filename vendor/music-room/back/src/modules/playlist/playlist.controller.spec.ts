import { Test, TestingModule } from '@nestjs/testing';
import { PlaylistController } from './playlist.controller';
import { PlaylistService } from './playlist.service';

describe('PlaylistController', () => {
  let controller: PlaylistController;
  let playlistService: jest.Mocked<Partial<PlaylistService>>;

  beforeEach(async () => {
    playlistService = {
      create: jest.fn(),
      findAll: jest.fn(),
      findById: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
      addTrack: jest.fn(),
      removeTrack: jest.fn(),
      reorderTracks: jest.fn(),
      getOperationsHistory: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [PlaylistController],
      providers: [{ provide: PlaylistService, useValue: playlistService }],
    }).compile();

    controller = module.get<PlaylistController>(PlaylistController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('create', () => {
    it('should create playlist with owner', async () => {
      const dto = { name: 'My Playlist' };
      const user = { _id: 'user1' };
      const playlist = { _id: 'pl1', ...dto, owner: 'user1' };
      playlistService.create.mockResolvedValue(playlist as any);

      const result = await controller.create(user as any, dto as any);

      expect(playlistService.create).toHaveBeenCalledWith(dto, 'user1');
      expect(result).toEqual(playlist);
    });
  });

  describe('findAll', () => {
    it('should return all playlists', async () => {
      const playlists = [{ _id: 'pl1' }, { _id: 'pl2' }];
      playlistService.findAll.mockResolvedValue(playlists as any);

      const result = await controller.findAll();

      expect(result).toHaveLength(2);
    });
  });

  describe('addTrack', () => {
    it('should add track with user id', async () => {
      const dto = { deezerTrackId: '123', title: 'Song', baseVersion: 0 };
      const user = { _id: 'user1' };
      playlistService.addTrack.mockResolvedValue({} as any);

      await controller.addTrack('pl1', user as any, dto as any);

      expect(playlistService.addTrack).toHaveBeenCalledWith('pl1', dto, 'user1');
    });
  });

  describe('removeTrack', () => {
    it('should remove track with user id', async () => {
      const dto = { deezerTrackId: '123', baseVersion: 1 };
      const user = { _id: 'user1' };
      playlistService.removeTrack.mockResolvedValue({} as any);

      await controller.removeTrack('pl1', user as any, dto as any);

      expect(playlistService.removeTrack).toHaveBeenCalledWith('pl1', dto, 'user1');
    });
  });

  describe('delete', () => {
    it('should delete playlist by owner', async () => {
      const user = { _id: 'user1' };
      playlistService.delete.mockResolvedValue(undefined);

      await controller.delete('pl1', user as any);

      expect(playlistService.delete).toHaveBeenCalledWith('pl1', 'user1');
    });
  });
});
