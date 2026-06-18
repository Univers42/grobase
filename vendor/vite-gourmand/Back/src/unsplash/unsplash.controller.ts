/**
 * Unsplash Controller - Endpoints to fetch real food photos
 */
import {
  Controller,
  Get,
  Query,
  ParseIntPipe,
  DefaultValuePipe,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiQuery, ApiResponse } from '@nestjs/swagger';
import { UnsplashService } from './unsplash.service';
import { Public } from '../common';

@ApiTags('Unsplash')
@Controller('unsplash')
export class UnsplashController {
  constructor(private readonly unsplashService: UnsplashService) {}

  @Get('search')
  @Public()
  @ApiOperation({ summary: 'Search for food photos on Unsplash' })
  @ApiQuery({ name: 'query', required: true, description: 'Search query' })
  @ApiQuery({
    name: 'perPage',
    required: false,
    description: 'Photos per page',
  })
  @ApiResponse({ status: 200, description: 'List of photos' })
  async searchPhotos(
    @Query('query') query: string,
    @Query('perPage', new DefaultValuePipe(30), ParseIntPipe) perPage: number,
  ) {
    return this.unsplashService.searchFoodPhotos(query, perPage);
  }

  @Get('random')
  @Public()
  @ApiOperation({ summary: 'Get random food photos for a category' })
  @ApiQuery({ name: 'category', required: true, description: 'Food category' })
  @ApiQuery({ name: 'count', required: false, description: 'Number of photos' })
  @ApiResponse({ status: 200, description: 'List of random photos' })
  async getRandomPhotos(
    @Query('category') category: string,
    @Query('count', new DefaultValuePipe(10), ParseIntPipe) count: number,
  ) {
    return this.unsplashService.getRandomFoodPhotos(
      category,
      Math.min(count, 30),
    );
  }

  @Get('random/single')
  @Public()
  @ApiOperation({ summary: 'Get a single random food photo' })
  @ApiQuery({ name: 'query', required: true, description: 'Search query' })
  @ApiResponse({ status: 200, description: 'Single random photo' })
  async getRandomPhoto(@Query('query') query: string) {
    return this.unsplashService.getRandomPhoto(query);
  }
}
