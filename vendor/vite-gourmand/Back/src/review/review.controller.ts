/**
 * Review Controller
 */
import { Controller, Get, Post, Put, Body, Param, Query } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { ReviewService } from './review.service';
import {
  Public,
  Roles,
  CurrentUser,
  JwtPayload,
  PaginationDto,
  SafeParseIntPipe,
} from '../common';
import { CreateReviewDto, ModerateReviewDto } from './dto/review.dto';

@ApiTags('reviews')
@Controller('reviews')
export class ReviewController {
  constructor(private readonly reviewService: ReviewService) {}

  // ─── Static routes MUST come before :id param route ───

  @Public()
  @Get('stats')
  @ApiOperation({
    summary: 'Get public review statistics (avg rating, count, satisfaction %)',
  })
  async getStats() {
    return this.reviewService.getPublicStats();
  }

  @Get('pending')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List pending reviews for moderation' })
  async findPending(@Query() pagination: PaginationDto) {
    return this.reviewService.findPending(pagination);
  }

  @Public()
  @Get()
  @ApiOperation({ summary: 'List approved reviews' })
  async findAll(@Query() pagination: PaginationDto) {
    return this.reviewService.findApproved(pagination);
  }

  // ─── Dynamic :id route MUST come last ───

  @Public()
  @Get(':id')
  @ApiOperation({ summary: 'Get review by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.reviewService.findById(id);
  }

  @Post()
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create new review' })
  async create(@CurrentUser() user: JwtPayload, @Body() dto: CreateReviewDto) {
    return this.reviewService.create(user.sub, dto);
  }

  @Put(':id/moderate')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Moderate review' })
  async moderate(
    @CurrentUser() user: JwtPayload,
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: ModerateReviewDto,
  ) {
    return this.reviewService.moderate(id, user.sub, dto);
  }
}
