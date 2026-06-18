/**
 * Theme Controller
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
import { ThemeService } from './theme.service';
import { Public, Roles, SafeParseIntPipe } from '../common';
import { CreateThemeDto, UpdateThemeDto } from './dto/theme.dto';

@ApiTags('themes')
@Controller('themes')
export class ThemeController {
  constructor(private readonly themeService: ThemeService) {}

  @Public()
  @Get()
  @ApiOperation({ summary: 'List all themes' })
  async findAll() {
    return this.themeService.findAll();
  }

  @Public()
  @Get(':id')
  @ApiOperation({ summary: 'Get theme by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.themeService.findById(id);
  }

  @Post()
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create new theme' })
  async create(@Body() dto: CreateThemeDto) {
    return this.themeService.create(dto);
  }

  @Put(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update theme' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateThemeDto,
  ) {
    return this.themeService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete theme' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.themeService.delete(id);
  }
}
