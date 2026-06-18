/**
 * Menu Module
 * Provides menu management functionality
 */
import { Module } from '@nestjs/common';
import { MenuController } from './menu.controller';
import { MenuService } from './menu.service';
import { MenuImageService } from './menu-image.service';

@Module({
  controllers: [MenuController],
  providers: [MenuService, MenuImageService],
  exports: [MenuService],
})
export class MenuModule {}
