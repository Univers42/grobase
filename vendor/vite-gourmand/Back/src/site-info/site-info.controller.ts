/**
 * Site Info Controller
 * Public endpoint for frontend to fetch dynamic site data
 */
import { Controller, Get } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { SiteInfoService } from './site-info.service';
import { Public } from '../common';

@ApiTags('site-info')
@Controller('site-info')
export class SiteInfoController {
  constructor(private readonly siteInfoService: SiteInfoService) {}

  @Public()
  @Get()
  @ApiOperation({
    summary: 'Get public site information (owners, stats, contact)',
  })
  async getInfo() {
    return this.siteInfoService.getPublicInfo();
  }
}
