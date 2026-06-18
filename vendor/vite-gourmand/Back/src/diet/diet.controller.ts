/**
 * Diet Controller
 */
import {
  Controller,
  Get,
  Post,
  Put,
  Delete,
  Body,
  Param,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { DietService } from './diet.service';
import { Public, Roles, SafeParseIntPipe } from '../common';
import { CreateDietDto, UpdateDietDto } from './dto/diet.dto';

@ApiTags('diets')
@Controller('diets')
export class DietController {
  constructor(private readonly dietService: DietService) {}

  @Public()
  @Get()
  @ApiOperation({ summary: 'List all diets' })
  async findAll() {
    return this.dietService.findAll();
  }

  @Public()
  @Get(':id')
  @ApiOperation({ summary: 'Get diet by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.dietService.findById(id);
  }

  @Post()
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create new diet' })
  async create(@Body() dto: CreateDietDto) {
    return this.dietService.create(dto);
  }

  @Put(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update diet' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateDietDto,
  ) {
    return this.dietService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete diet' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.dietService.delete(id);
  }
}
