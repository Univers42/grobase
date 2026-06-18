/**
 * Ingredient Controller
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
import { IngredientService } from './ingredient.service';
import { Roles, SafeParseIntPipe } from '../common';
import {
  CreateIngredientDto,
  UpdateIngredientDto,
  RestockIngredientDto,
} from './dto/ingredient.dto';

@ApiTags('ingredients')
@Controller('ingredients')
@ApiBearerAuth()
export class IngredientController {
  constructor(private readonly ingredientService: IngredientService) {}

  @Get()
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'List all ingredients' })
  async findAll(@Query('lowStockOnly') lowStockOnly?: string) {
    return this.ingredientService.findAll({
      lowStockOnly: lowStockOnly === 'true',
    });
  }

  @Get('low-stock')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get low stock ingredients' })
  async getLowStock() {
    return this.ingredientService.getLowStock();
  }

  @Get(':id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get ingredient by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.ingredientService.findById(id);
  }

  @Post()
  @Roles('admin')
  @ApiOperation({ summary: 'Create new ingredient' })
  async create(@Body() dto: CreateIngredientDto) {
    return this.ingredientService.create(dto);
  }

  @Put(':id')
  @Roles('admin')
  @ApiOperation({ summary: 'Update ingredient' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateIngredientDto,
  ) {
    return this.ingredientService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete ingredient' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.ingredientService.delete(id);
  }

  @Post(':id/restock')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Restock ingredient' })
  async restock(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: RestockIngredientDto,
  ) {
    return this.ingredientService.restock(id, dto);
  }

  @Get('dish/:dishId')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get ingredients for a dish' })
  async getForDish(@Param('dishId', SafeParseIntPipe) dishId: number) {
    return this.ingredientService.getUsageForDish(dishId);
  }

  @Get('menu/:menuId')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get ingredients for a menu' })
  async getForMenu(@Param('menuId', SafeParseIntPipe) menuId: number) {
    return this.ingredientService.getUsageForMenu(menuId);
  }
}
