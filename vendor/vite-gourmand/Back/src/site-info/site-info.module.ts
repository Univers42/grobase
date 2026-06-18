/**
 * Site Info Module
 */
import { Module } from '@nestjs/common';
import { SiteInfoController } from './site-info.controller';
import { SiteInfoService } from './site-info.service';

@Module({
  controllers: [SiteInfoController],
  providers: [SiteInfoService],
})
export class SiteInfoModule {}
