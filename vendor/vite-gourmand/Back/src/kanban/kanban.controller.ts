/**
 * Kanban Controller
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
import { KanbanService } from './kanban.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import {
  CreateKanbanColumnDto,
  UpdateKanbanColumnDto,
  CreateOrderTagDto,
  UpdateOrderTagDto,
} from './dto/kanban.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('kanban')
@Controller('kanban')
@ApiBearerAuth()
export class KanbanController {
  constructor(private readonly kanbanService: KanbanService) {}

  // Board
  @Get('board')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get kanban board with orders' })
  async getBoard() {
    return this.kanbanService.getKanbanBoard();
  }

  // Columns
  @Get('columns')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'List all kanban columns' })
  async findAllColumns(@Query('activeOnly') activeOnly?: string) {
    return this.kanbanService.findAllColumns({
      activeOnly: activeOnly === 'true',
    });
  }

  @Get('columns/:id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get column by ID' })
  async findColumn(@Param('id', SafeParseIntPipe) id: number) {
    return this.kanbanService.findColumnById(id);
  }

  @Post('columns')
  @Roles('admin')
  @ApiOperation({ summary: 'Create kanban column' })
  async createColumn(
    @Body() dto: CreateKanbanColumnDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.kanbanService.createColumn(dto, user.sub);
  }

  @Put('columns/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Update kanban column' })
  async updateColumn(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateKanbanColumnDto,
  ) {
    return this.kanbanService.updateColumn(id, dto);
  }

  @Delete('columns/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete kanban column' })
  async deleteColumn(@Param('id', SafeParseIntPipe) id: number) {
    return this.kanbanService.deleteColumn(id);
  }

  @Post('columns/reorder')
  @Roles('admin')
  @ApiOperation({ summary: 'Reorder kanban columns' })
  async reorderColumns(@Body() body: { columnIds: number[] }) {
    return this.kanbanService.reorderColumns(body.columnIds);
  }

  // Tags
  @Get('tags')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'List all order tags' })
  async findAllTags() {
    return this.kanbanService.findAllTags();
  }

  @Get('tags/:id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get tag by ID' })
  async findTag(@Param('id', SafeParseIntPipe) id: number) {
    return this.kanbanService.findTagById(id);
  }

  @Post('tags')
  @Roles('admin')
  @ApiOperation({ summary: 'Create order tag' })
  async createTag(
    @Body() dto: CreateOrderTagDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.kanbanService.createTag(dto, user.sub);
  }

  @Put('tags/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Update order tag' })
  async updateTag(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateOrderTagDto,
  ) {
    return this.kanbanService.updateTag(id, dto);
  }

  @Delete('tags/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete order tag' })
  async deleteTag(@Param('id', SafeParseIntPipe) id: number) {
    return this.kanbanService.deleteTag(id);
  }

  // Order-Tag associations
  @Post('orders/:orderId/tags/:tagId')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Add tag to order' })
  async addTagToOrder(
    @Param('orderId', SafeParseIntPipe) orderId: number,
    @Param('tagId', SafeParseIntPipe) tagId: number,
  ) {
    return this.kanbanService.addTagToOrder(orderId, tagId);
  }

  @Delete('orders/:orderId/tags/:tagId')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Remove tag from order' })
  async removeTagFromOrder(
    @Param('orderId', SafeParseIntPipe) orderId: number,
    @Param('tagId', SafeParseIntPipe) tagId: number,
  ) {
    return this.kanbanService.removeTagFromOrder(orderId, tagId);
  }

  @Get('orders/:orderId/tags')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get tags for order' })
  async getOrderTags(@Param('orderId', SafeParseIntPipe) orderId: number) {
    return this.kanbanService.getOrderTags(orderId);
  }
}
