/**
 * Image Module
 */
import { Module } from '@nestjs/common';
import { ImageController } from './image.controller';
import { ImageService } from './image.service';
import { MenuImageService } from './menu-image.service';
import { ReviewImageService } from './review-image.service';
import { PrismaModule } from '../prisma';

@Module({
  imports: [PrismaModule],
  controllers: [ImageController],
  providers: [ImageService, MenuImageService, ReviewImageService],
  exports: [ImageService, MenuImageService, ReviewImageService],
})
export class ImageModule {}
