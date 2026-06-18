/**
 * Image Controller
 */
import {
  Controller,
  Get,
  Post,
  Put,
  Delete,
  Body,
  Param,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { ImageService } from './image.service';
import { Roles, SafeParseIntPipe, CurrentUser, Public } from '../common';
import {
  CreateMenuImageDto,
  UpdateMenuImageDto,
  CreateReviewImageDto,
} from './dto/image.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('images')
@Controller('images')
@ApiBearerAuth()
export class ImageController {
  constructor(private readonly imageService: ImageService) {}

  // ============ Menu Images ============

  @Get('menu/:menuItemId')
  @Public()
  @ApiOperation({ summary: 'Get images for menu item' })
  async getMenuItemImages(
    @Param('menuItemId', SafeParseIntPipe) menuItemId: number,
  ) {
    return this.imageService.getMenuItemImages(menuItemId);
  }

  @Get('menu/image/:id')
  @Public()
  @ApiOperation({ summary: 'Get menu image by ID' })
  async getMenuImageById(@Param('id', SafeParseIntPipe) id: number) {
    return this.imageService.getMenuImageById(id);
  }

  @Post('menu')
  @Roles('admin')
  @ApiOperation({ summary: 'Create menu image (admin)' })
  async createMenuImage(@Body() dto: CreateMenuImageDto) {
    return this.imageService.createMenuImage(dto);
  }

  @Put('menu/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Update menu image (admin)' })
  async updateMenuImage(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateMenuImageDto,
  ) {
    return this.imageService.updateMenuImage(id, dto);
  }

  @Post('menu/:id/set-primary')
  @Roles('admin')
  @ApiOperation({ summary: 'Set menu image as primary (admin)' })
  async setMenuImageAsPrimary(@Param('id', SafeParseIntPipe) id: number) {
    return this.imageService.setMenuImageAsPrimary(id);
  }

  @Delete('menu/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete menu image (admin)' })
  async deleteMenuImage(@Param('id', SafeParseIntPipe) id: number) {
    return this.imageService.deleteMenuImage(id);
  }

  @Post('menu/:menuItemId/reorder')
  @Roles('admin')
  @ApiOperation({ summary: 'Reorder menu images (admin)' })
  async reorderMenuImages(
    @Param('menuItemId', SafeParseIntPipe) menuItemId: number,
    @Body() body: { imageIds: number[] },
  ) {
    return this.imageService.reorderMenuImages(menuItemId, body.imageIds);
  }

  // ============ Review Images ============

  @Get('review/:reviewId')
  @Public()
  @ApiOperation({ summary: 'Get images for review' })
  async getReviewImages(@Param('reviewId', SafeParseIntPipe) reviewId: number) {
    return this.imageService.getReviewImages(reviewId);
  }

  @Get('review/image/:id')
  @Public()
  @ApiOperation({ summary: 'Get review image by ID' })
  async getReviewImageById(@Param('id', SafeParseIntPipe) id: number) {
    return this.imageService.getReviewImageById(id);
  }

  @Post('review')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Add image to my review' })
  async createReviewImage(
    @Body() dto: CreateReviewImageDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.imageService.createReviewImage(dto, user.sub);
  }

  @Put('review/:id')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({
    summary: 'Get review image (review images cannot be updated)',
  })
  async updateReviewImage(@Param('id', SafeParseIntPipe) id: number) {
    return this.imageService.updateReviewImage(id);
  }

  @Delete('review/:id')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Delete my review image' })
  async deleteReviewImage(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.imageService.deleteReviewImage(id, user.sub);
  }

  // Admin review image endpoints
  @Post('admin/review')
  @Roles('admin')
  @ApiOperation({ summary: 'Create review image (admin)' })
  async createReviewImageAdmin(@Body() dto: CreateReviewImageDto) {
    return this.imageService.createReviewImageAdmin(dto);
  }

  @Delete('admin/review/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete review image (admin)' })
  async deleteReviewImageAdmin(@Param('id', SafeParseIntPipe) id: number) {
    return this.imageService.deleteReviewImageAdmin(id);
  }
}
