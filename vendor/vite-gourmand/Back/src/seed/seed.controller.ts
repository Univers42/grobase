/**
 * Seed Controller - API endpoints for updating menu images
 */
import { Controller, Post } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse } from '@nestjs/swagger';
import { SeedService } from './seed.service';
import { Roles } from '../common';

@ApiTags('Seed')
@Controller('seed')
export class SeedController {
  constructor(private readonly seedService: SeedService) {}

  @Post('menu-images')
  @Roles('admin')
  @ApiOperation({ summary: 'Update menu images with Unsplash photos' })
  @ApiResponse({ status: 201, description: 'Menu images updated successfully' })
  async updateMenuImages() {
    const result = await this.seedService.updateMenuImages();
    return {
      success: true,
      message: `Updated ${result.updated} menu images (${result.errors} errors)`,
      ...result,
    };
  }
}
