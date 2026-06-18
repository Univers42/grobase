import { Test, TestingModule } from '@nestjs/testing';
import { MusicController } from './music.controller';
import { MusicService } from './music.service';

describe('MusicController', () => {
  let controller: MusicController;
  let musicService: jest.Mocked<Partial<MusicService>>;

  beforeEach(async () => {
    musicService = {
      searchTracks: jest.fn(),
      getTrack: jest.fn(),
      getArtist: jest.fn(),
      getAlbum: jest.fn(),
      getArtistTopTracks: jest.fn(),
      searchArtists: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [MusicController],
      providers: [{ provide: MusicService, useValue: musicService }],
    }).compile();

    controller = module.get<MusicController>(MusicController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('searchTracks', () => {
    it('should call service with query and limit', async () => {
      const mockResult = { data: [{ id: 1, title: 'Song' }] };
      musicService.searchTracks.mockResolvedValue(mockResult);

      const result = await controller.searchTracks('test', 10);

      expect(musicService.searchTracks).toHaveBeenCalledWith('test', 10);
      expect(result).toEqual(mockResult);
    });

    it('should use default limit', async () => {
      musicService.searchTracks.mockResolvedValue({ data: [] });

      await controller.searchTracks('test');

      expect(musicService.searchTracks).toHaveBeenCalledWith('test', undefined);
    });
  });

  describe('getTrack', () => {
    it('should return track by id', async () => {
      const track = { id: 123, title: 'Test Track' };
      musicService.getTrack.mockResolvedValue(track);

      const result = await controller.getTrack('123');

      expect(musicService.getTrack).toHaveBeenCalledWith(123);
      expect(result).toEqual(track);
    });
  });

  describe('getArtist', () => {
    it('should return artist by id', async () => {
      const artist = { id: 456, name: 'Test Artist' };
      musicService.getArtist.mockResolvedValue(artist);

      const result = await controller.getArtist('456');

      expect(musicService.getArtist).toHaveBeenCalledWith(456);
      expect(result).toEqual(artist);
    });
  });

  describe('getAlbum', () => {
    it('should return album by id', async () => {
      const album = { id: 789, title: 'Test Album' };
      musicService.getAlbum.mockResolvedValue(album);

      const result = await controller.getAlbum('789');

      expect(musicService.getAlbum).toHaveBeenCalledWith(789);
      expect(result).toEqual(album);
    });
  });
});
