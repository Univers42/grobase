import { Test, TestingModule } from '@nestjs/testing';
import { PlaylistService } from './playlist.service';
import { getModelToken } from '@nestjs/mongoose';
import { NotFoundException, ForbiddenException, ConflictException } from '@nestjs/common';

describe('PlaylistService', () => {
  let service: PlaylistService;
  let mockPlaylistModel: any;

  const mockPlaylist = {
    _id: 'playlist123',
    name: 'Test Playlist',
    creator: 'user123',
    visibility: 'public',
    collaborationType: 'collaborative',
    collaborators: ['user456'],
    tracks: [
      { trackId: 'track1', title: 'Song 1', artist: 'Artist 1', position: 0, addedBy: 'user123' },
      { trackId: 'track2', title: 'Song 2', artist: 'Artist 2', position: 1, addedBy: 'user456' },
    ],
    version: 5,
    save: jest.fn().mockResolvedValue(true),
    toObject: jest.fn().mockReturnThis(),
  };

  beforeEach(async () => {
    const ModelConstructor: any = jest.fn().mockImplementation((data) => ({
      ...data,
      _id: 'newPlaylist123',
      tracks: [],
      version: 0,
      save: jest.fn().mockResolvedValue({ _id: 'newPlaylist123', ...data, version: 0 }),
    }));

    ModelConstructor.find = jest.fn();
    ModelConstructor.findById = jest.fn();
    ModelConstructor.findOne = jest.fn();
    ModelConstructor.findOneAndUpdate = jest.fn();
    ModelConstructor.findByIdAndDelete = jest.fn();

    mockPlaylistModel = ModelConstructor;

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        PlaylistService,
        { provide: getModelToken('Playlist'), useValue: ModelConstructor },
        { provide: getModelToken('PlaylistOperation'), useValue: { create: jest.fn() } },
      ],
    }).compile();

    service = module.get<PlaylistService>(PlaylistService);
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  describe('create', () => {
    it('should create a playlist with initial version 0', async () => {
      const dto = {
        name: 'My Playlist',
        visibility: 'public' as const,
        collaborationType: 'collaborative' as const,
      };

      const result = await service.create(dto, 'user123');
      expect(result).toBeDefined();
      expect(result.version).toBe(0);
    });
  });

  describe('findById', () => {
    it('should throw NotFoundException when playlist not found', async () => {
      mockPlaylistModel.findById.mockReturnValue({
        populate: jest.fn().mockResolvedValue(null),
      });

      await expect(service.findById('nonexistent')).rejects.toThrow(NotFoundException);
    });

    it('should return playlist when found', async () => {
      mockPlaylistModel.findById.mockReturnValue({
        populate: jest.fn().mockResolvedValue(mockPlaylist),
      });

      const result = await service.findById('playlist123');
      expect(result.name).toBe('Test Playlist');
      expect(result.tracks).toHaveLength(2);
    });
  });

  describe('addTrack', () => {
    it('should reject add with stale baseVersion (conflict)', async () => {
      mockPlaylistModel.findById.mockResolvedValue({
        ...mockPlaylist,
        version: 5,
      });

      await expect(
        service.addTrack(
          'playlist123',
          { trackId: 'track3', title: 'New', artist: 'A', baseVersion: 3 },
          'user123',
        ),
      ).rejects.toThrow(ConflictException);
    });
  });

  describe('removeTrack', () => {
    it('should throw NotFoundException when track not in playlist', async () => {
      mockPlaylistModel.findOneAndUpdate.mockResolvedValue(null);

      await expect(
        service.removeTrack('playlist123', 'nonexistent', 5, 'user123'),
      ).rejects.toThrow(NotFoundException);
    });
  });

  describe('delete', () => {
    it('should throw ForbiddenException when non-owner tries to delete', async () => {
      mockPlaylistModel.findById.mockResolvedValue({
        ...mockPlaylist,
        creator: { toString: () => 'otherUser' },
      });

      await expect(
        service.delete('playlist123', 'user123'),
      ).rejects.toThrow(ForbiddenException);
    });
  });
});
