/**
 * Unsplash Service - Fetches real food photos from Unsplash API
 */
import { Injectable, Logger, HttpException, HttpStatus } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

export interface UnsplashPhoto {
  id: string;
  urls: {
    raw: string;
    full: string;
    regular: string;
    small: string;
    thumb: string;
  };
  alt_description: string | null;
  description: string | null;
  user: {
    name: string;
    username: string;
  };
}

export interface UnsplashSearchResult {
  total: number;
  total_pages: number;
  results: UnsplashPhoto[];
}

@Injectable()
export class UnsplashService {
  private readonly logger = new Logger(UnsplashService.name);
  private readonly apiUrl = 'https://api.unsplash.com';
  private readonly accessKey: string;

  constructor(private readonly configService: ConfigService) {
    this.accessKey = this.configService.get<string>('API_UNSPLASH_PKEY') || '';
    if (!this.accessKey) {
      this.logger.warn('Unsplash API key not configured');
    }
  }

  /**
   * Search for food photos on Unsplash
   */
  async searchFoodPhotos(
    query: string,
    perPage = 30,
  ): Promise<UnsplashPhoto[]> {
    if (!this.accessKey) {
      throw new HttpException(
        'Unsplash API not configured',
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    const searchQuery = `${query} food`;
    const url = `${this.apiUrl}/search/photos?query=${encodeURIComponent(searchQuery)}&per_page=${perPage}&orientation=landscape`;

    return this.fetchFromUnsplash<UnsplashSearchResult>(url).then(
      (r) => r.results,
    );
  }

  /**
   * Get random food photos for a category
   */
  async getRandomFoodPhotos(
    category: string,
    count = 10,
  ): Promise<UnsplashPhoto[]> {
    if (!this.accessKey) {
      throw new HttpException(
        'Unsplash API not configured',
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    const url = `${this.apiUrl}/photos/random?query=${encodeURIComponent(category + ' food')}&count=${count}&orientation=landscape`;

    return this.fetchFromUnsplash<UnsplashPhoto[]>(url);
  }

  /**
   * Get a single random food photo
   */
  async getRandomPhoto(query: string): Promise<UnsplashPhoto> {
    if (!this.accessKey) {
      throw new HttpException(
        'Unsplash API not configured',
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    const url = `${this.apiUrl}/photos/random?query=${encodeURIComponent(query + ' food')}&orientation=landscape`;

    return this.fetchFromUnsplash<UnsplashPhoto>(url);
  }

  /**
   * Fetch from Unsplash API
   */
  private async fetchFromUnsplash<T>(url: string): Promise<T> {
    try {
      const response = await fetch(url, {
        headers: {
          Authorization: `Client-ID ${this.accessKey}`,
          'Accept-Version': 'v1',
        },
      });

      if (!response.ok) {
        const errorText = await response.text();
        this.logger.error(
          `Unsplash API error: ${response.status} - ${errorText}`,
        );
        throw new HttpException(
          `Unsplash API error: ${response.statusText}`,
          response.status,
        );
      }

      return response.json() as Promise<T>;
    } catch (error) {
      if (error instanceof HttpException) throw error;
      this.logger.error(`Failed to fetch from Unsplash: ${String(error)}`);
      throw new HttpException(
        'Failed to fetch from Unsplash',
        HttpStatus.BAD_GATEWAY,
      );
    }
  }
}
