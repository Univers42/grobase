import { Injectable, HttpException, HttpStatus } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

const DEEZER_API_BASE = 'https://api.deezer.com';

export interface DeezerTrack {
  id: number;
  title: string;
  duration: number;
  preview: string; // 30s preview URL
  artist: { id: number; name: string; picture_medium: string };
  album: { id: number; title: string; cover_medium: string };
}

export interface DeezerSearchResult {
  data: DeezerTrack[];
  total: number;
  next?: string;
}

@Injectable()
export class MusicService {
  constructor(private readonly configService: ConfigService) {}

  // ─── Search Tracks ───────────────────────────────────

  async searchTracks(query: string, limit = 25, index = 0): Promise<DeezerSearchResult> {
    const url = `${DEEZER_API_BASE}/search?q=${encodeURIComponent(query)}&limit=${limit}&index=${index}`;
    return this.fetchDeezer<DeezerSearchResult>(url);
  }

  // ─── Get Track Details ───────────────────────────────

  async getTrack(trackId: number): Promise<DeezerTrack> {
    const url = `${DEEZER_API_BASE}/track/${trackId}`;
    return this.fetchDeezer<DeezerTrack>(url);
  }

  // ─── Get Artist Details ──────────────────────────────

  async getArtist(artistId: number) {
    const url = `${DEEZER_API_BASE}/artist/${artistId}`;
    return this.fetchDeezer(url);
  }

  // ─── Get Album Details ───────────────────────────────

  async getAlbum(albumId: number) {
    const url = `${DEEZER_API_BASE}/album/${albumId}`;
    return this.fetchDeezer(url);
  }

  // ─── Get Artist Top Tracks ───────────────────────────

  async getArtistTopTracks(artistId: number, limit = 10) {
    const url = `${DEEZER_API_BASE}/artist/${artistId}/top?limit=${limit}`;
    return this.fetchDeezer(url);
  }

  // ─── Search Artists ──────────────────────────────────

  async searchArtists(query: string, limit = 10) {
    const url = `${DEEZER_API_BASE}/search/artist?q=${encodeURIComponent(query)}&limit=${limit}`;
    return this.fetchDeezer(url);
  }

  // ─── Deezer API Fetch Helper ─────────────────────────

  private async fetchDeezer<T = unknown>(url: string): Promise<T> {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        throw new HttpException(
          `Deezer API error: ${response.statusText}`,
          HttpStatus.BAD_GATEWAY,
        );
      }
      const data = (await response.json()) as any;
      if (data.error) {
        throw new HttpException(
          `Deezer API error: ${data.error.message || 'Unknown error'}`,
          HttpStatus.BAD_GATEWAY,
        );
      }
      return data as T;
    } catch (error) {
      if (error instanceof HttpException) throw error;
      throw new HttpException('Failed to fetch from Deezer API', HttpStatus.BAD_GATEWAY);
    }
  }
}
