import { Test, TestingModule } from '@nestjs/testing';
import { MusicService } from './music.service';

describe('MusicService', () => {
  let service: MusicService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [MusicService],
    }).compile();

    service = module.get<MusicService>(MusicService);
  });

  // Mock global fetch
  const mockFetch = jest.fn();
  beforeAll(() => {
    global.fetch = mockFetch;
  });
  afterAll(() => {
    delete (global as any).fetch;
  });
  afterEach(() => {
    mockFetch.mockReset();
  });

  describe('searchTracks', () => {
    it('should call Deezer API with correct URL', async () => {
      const mockResponse = {
        data: [
          { id: 1, title: 'Test Track', artist: { name: 'Artist' } },
        ],
        total: 1,
      };
      mockFetch.mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue(mockResponse),
      });

      const result = await service.searchTracks('test query');

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining('api.deezer.com/search?q=test%20query'),
      );
      expect(result).toEqual(mockResponse);
    });

    it('should pass limit parameter', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({ data: [], total: 0 }),
      });

      await service.searchTracks('test', 10);

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining('limit=10'),
      );
    });

    it('should throw on API error', async () => {
      mockFetch.mockResolvedValue({
        ok: false,
        status: 500,
        statusText: 'Internal Server Error',
      });

      await expect(service.searchTracks('test')).rejects.toThrow();
    });
  });

  describe('getTrack', () => {
    it('should fetch a single track by ID', async () => {
      const mockTrack = { id: 123, title: 'Rock Track', preview: 'https://...' };
      mockFetch.mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue(mockTrack),
      });

      const result = await service.getTrack(123);

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining('api.deezer.com/track/123'),
      );
      expect(result).toEqual(mockTrack);
    });
  });

  describe('getArtist', () => {
    it('should fetch artist by ID', async () => {
      const mockArtist = { id: 456, name: 'Test Artist' };
      mockFetch.mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue(mockArtist),
      });

      const result = await service.getArtist(456);

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining('api.deezer.com/artist/456'),
      );
      expect(result).toEqual(mockArtist);
    });
  });

  describe('getAlbum', () => {
    it('should fetch album by ID', async () => {
      const mockAlbum = { id: 789, title: 'Test Album' };
      mockFetch.mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue(mockAlbum),
      });

      const result = await service.getAlbum(789);

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining('api.deezer.com/album/789'),
      );
      expect(result).toEqual(mockAlbum);
    });
  });
});
