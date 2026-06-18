/**
 * Working Hours Controller
 */
import { Controller, Get, Put, Body, Param } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { WorkingHoursService } from './working-hours.service';
import { Public, Roles } from '../common';
import { UpdateWorkingHoursDto } from './dto/working-hours.dto';

@ApiTags('working-hours')
@Controller('working-hours')
export class WorkingHoursController {
  constructor(private readonly service: WorkingHoursService) {}

  @Public()
  @Get()
  @ApiOperation({ summary: 'Get all working hours' })
  async findAll() {
    return this.service.findAll();
  }

  @Put(':day')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update working hours for a day' })
  async update(@Param('day') day: string, @Body() dto: UpdateWorkingHoursDto) {
    return this.service.update(day, dto);
  }
}
