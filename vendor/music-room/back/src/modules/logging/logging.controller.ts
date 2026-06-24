import { Controller, Get, Query } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation, ApiQuery } from '@nestjs/swagger';
import { LoggingService } from './logging.service';

@ApiTags('admin/logs')
@ApiBearerAuth()
@Controller('admin/logs')
export class LoggingController {
  constructor(private readonly loggingService: LoggingService) {}

  @Get('platforms')
  @ApiOperation({ summary: 'Get platform usage statistics' })
  @ApiQuery({ name: 'days', required: false, type: Number })
  async platformStats(@Query('days') days = 30) {
    return this.loggingService.getPlatformStats(+days);
  }

  @Get('errors')
  @ApiOperation({ summary: 'Get error rate statistics' })
  @ApiQuery({ name: 'days', required: false, type: Number })
  async errorStats(@Query('days') days = 7) {
    return this.loggingService.getErrorStats(+days);
  }

  @Get('slow')
  @ApiOperation({ summary: 'Get slowest endpoints' })
  @ApiQuery({ name: 'limit', required: false, type: Number })
  async slowEndpoints(@Query('limit') limit = 10) {
    return this.loggingService.getSlowestEndpoints(+limit);
  }

  @Get()
  @ApiOperation({ summary: 'Get recent logs (paginated)' })
  @ApiQuery({ name: 'page', required: false, type: Number })
  @ApiQuery({ name: 'limit', required: false, type: Number })
  async recentLogs(
    @Query('page') page = 1,
    @Query('limit') limit = 50,
  ) {
    return this.loggingService.getRecentLogs(+page, +limit);
  }
}
