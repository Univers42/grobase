/**
 * Allergen Controller
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
import { AllergenService } from './allergen.service';
import { Public, Roles, SafeParseIntPipe } from '../common';
import { CreateAllergenDto, UpdateAllergenDto } from './dto/allergen.dto';

@ApiTags('allergens')
@Controller('allergens')
export class AllergenController {
  constructor(private readonly allergenService: AllergenService) {}

  @Public()
  @Get()
  @ApiOperation({ summary: 'List all allergens' })
  async findAll() {
    return this.allergenService.findAll();
  }

  @Public()
  @Get(':id')
  @ApiOperation({ summary: 'Get allergen by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.allergenService.findById(id);
  }

  @Post()
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create new allergen' })
  async create(@Body() dto: CreateAllergenDto) {
    return this.allergenService.create(dto);
  }

  @Put(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update allergen' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateAllergenDto,
  ) {
    return this.allergenService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete allergen' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.allergenService.delete(id);
  }
}
