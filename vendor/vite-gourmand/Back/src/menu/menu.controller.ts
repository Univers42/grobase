/**
 * Menu Controller
 * Menu management endpoints
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
import { MenuService } from './menu.service';
import {
  Public,
  Roles,
  CurrentUser,
  JwtPayload,
  SafeParseIntPipe,
} from '../common';
import { CreateMenuDto, UpdateMenuDto, MenuFilterDto } from './dto/menu.dto';

@ApiTags('menus')
@Controller('menus')
export class MenuController {
  constructor(private readonly menuService: MenuService) {}

  @Public()
  @Get()
  @ApiOperation({ summary: 'List published menus' })
  async findAll(@Query() filters: MenuFilterDto) {
    return this.menuService.findAll(filters);
  }

  @Public()
  @Get(':id')
  @ApiOperation({ summary: 'Get menu by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.menuService.findById(id);
  }

  @Post()
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create new menu' })
  async create(@Body() dto: CreateMenuDto, @CurrentUser() user: JwtPayload) {
    return this.menuService.create(dto, user.sub);
  }

  @Put(':id')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Update menu' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateMenuDto,
  ) {
    return this.menuService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete menu' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.menuService.delete(id);
  }

  @Post(':id/publish')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Publish menu' })
  async publish(@Param('id', SafeParseIntPipe) id: number) {
    return this.menuService.publish(id);
  }

  @Post(':id/unpublish')
  @Roles('admin', 'manager')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Unpublish menu' })
  async unpublish(@Param('id', SafeParseIntPipe) id: number) {
    return this.menuService.unpublish(id);
  }
}
