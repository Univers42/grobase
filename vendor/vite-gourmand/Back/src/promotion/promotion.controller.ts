/**
 * Promotion Controller
 * Public & admin endpoints for promotions and publicity.
 */
import {
  Controller,
  Get,
  Post,
  Put,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { PromotionService } from './promotion.service';
import {
  Public,
  Roles,
  CurrentUser,
  JwtPayload,
  PaginationDto,
  SafeParseIntPipe,
} from '../common';
import {
  CreatePromotionDto,
  UpdatePromotionDto,
  AssignPromotionDto,
} from './dto/promotion.dto';

@ApiTags('promotions')
@Controller('promotions')
export class PromotionController {
  constructor(private readonly promotionService: PromotionService) {}

  // ─── Public endpoints ───────────────────────────────

  @Public()
  @Get('active')
  @ApiOperation({
    summary: 'Get currently active public promotions (banners / publicity)',
  })
  async getActive() {
    return this.promotionService.getActivePublic();
  }

  // ─── Authenticated user endpoints ───────────────────

  @Get('mine')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get promotions assigned to the current user' })
  async getMyPromotions(@CurrentUser() user: JwtPayload) {
    return this.promotionService.getUserPromotions(user.sub);
  }

  @Put('mine/:promotionId/seen')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Mark a user promotion as seen' })
  async markSeen(
    @CurrentUser() user: JwtPayload,
    @Param('promotionId', SafeParseIntPipe) promotionId: number,
  ) {
    return this.promotionService.markSeen(user.sub, promotionId);
  }

  @Put('mine/:promotionId/used')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Mark a user promotion as used' })
  async markUsed(
    @CurrentUser() user: JwtPayload,
    @Param('promotionId', SafeParseIntPipe) promotionId: number,
  ) {
    return this.promotionService.markUsed(user.sub, promotionId);
  }

  // ─── Admin endpoints ───────────────────────────────

  @Get()
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List all promotions (admin)' })
  async findAll(
    @Query() pagination: PaginationDto,
    @Query('active') active?: string,
  ) {
    let activeOnly: boolean | undefined;
    if (active === 'true') activeOnly = true;
    if (active === 'false') activeOnly = false;
    return this.promotionService.findAll(pagination, activeOnly);
  }

  @Get(':id')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get promotion details (admin)' })
  async findById(@Param('id', SafeParseIntPipe) id: number) {
    return this.promotionService.findById(id);
  }

  @Post()
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create a promotion' })
  async create(
    @CurrentUser() user: JwtPayload,
    @Body() dto: CreatePromotionDto,
  ) {
    return this.promotionService.create(dto, user.sub);
  }

  @Put(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update a promotion' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdatePromotionDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.promotionService.update(id, dto, user.sub);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete a promotion' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.promotionService.delete(id);
  }

  @Post('assign')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Assign a promotion to a user' })
  async assign(@Body() dto: AssignPromotionDto) {
    return this.promotionService.assignToUser(dto.promotion_id, dto.user_id);
  }
}
