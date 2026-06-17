import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiSecurity, ApiTags } from '@nestjs/swagger';
import { ServiceTokenGuard } from '@mini-baas/common';
import { DecidePermissionDto } from './dto/decision.dto';
import { DecisionsService } from './decisions.service';

@ApiTags('permissions')
@Controller('permissions')
@UseGuards(ServiceTokenGuard)
export class DecisionsController {
  constructor(private readonly service: DecisionsService) {}

  @Post('decide')
  @ApiSecurity('service-token')
  @ApiOperation({ summary: 'Central ABAC decision endpoint for gateway pre-dispatch checks' })
  decide(@Body() dto: DecidePermissionDto) {
    return this.service.decide(dto);
  }
}