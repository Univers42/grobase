/**
 * Dish Controller
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
import { DishService } from './dish.service';
import { Public, Roles, PaginationDto, SafeParseIntPipe } from '../common';
import { CreateDishDto, UpdateDishDto } from './dto/dish.dto';

@ApiTags('dishes')
@Controller('dishes')
export class DishController {
  constructor(private readonly dishService: DishService) {}

  @Public()
  @Get()
  @ApiOperation({ summary: 'List all dishes' })
  async findAll(@Query() pagination: PaginationDto) {
    return this.dishService.findAll(pagination);
  }

  @Public()
  @Get(':id')
  @ApiOperation({ summary: 'Get dish by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.dishService.findById(id);
  }

  @Post()
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create new dish' })
  async create(@Body() dto: CreateDishDto) {
    return this.dishService.create(dto);
  }

  @Put(':id')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update dish' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateDishDto,
  ) {
    return this.dishService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete dish' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.dishService.delete(id);
  }
}
