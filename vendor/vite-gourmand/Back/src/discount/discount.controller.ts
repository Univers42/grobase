/**
 * Discount Controller
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
import { DiscountService } from './discount.service';
import { Public, Roles, SafeParseIntPipe, CurrentUser } from '../common';
import {
  CreateDiscountDto,
  UpdateDiscountDto,
  ValidateDiscountDto,
} from './dto/discount.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('discounts')
@Controller('discounts')
export class DiscountController {
  constructor(private readonly discountService: DiscountService) {}

  @Get()
  @Roles('admin', 'employee')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List all discounts' })
  async findAll(@Query('activeOnly') activeOnly?: string) {
    return this.discountService.findAll({
      activeOnly: activeOnly === 'true',
    });
  }

  @Get(':id')
  @Roles('admin', 'employee')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get discount by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.discountService.findById(id);
  }

  @Post()
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create new discount' })
  async create(
    @Body() dto: CreateDiscountDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.discountService.create(dto, user.sub);
  }

  @Put(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update discount' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateDiscountDto,
  ) {
    return this.discountService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete discount' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.discountService.delete(id);
  }

  @Public()
  @Post('validate')
  @ApiOperation({ summary: 'Validate a discount code (public)' })
  async validate(@Body() dto: ValidateDiscountDto) {
    return this.discountService.validate(dto);
  }
}
