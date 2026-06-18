/**
 * Contact Controller
 */
import {
  Controller,
  Get,
  Post,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { ContactService } from './contact.service';
import { Public, Roles, SafeParseIntPipe } from '../common';
import { CreateContactMessageDto } from './dto/contact.dto';

@ApiTags('contact')
@Controller('contact')
export class ContactController {
  constructor(private readonly contactService: ContactService) {}

  @Get()
  @Roles('admin', 'employee')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List all contact messages (admin/employee only)' })
  async findAll(
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.contactService.findAll({
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Get('count')
  @Roles('admin', 'employee')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Count contact messages' })
  async count() {
    return { count: await this.contactService.count() };
  }

  @Get(':id')
  @Roles('admin', 'employee')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get contact message by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.contactService.findById(id);
  }

  @Public()
  @Post()
  @ApiOperation({ summary: 'Submit a contact message (public)' })
  async create(@Body() dto: CreateContactMessageDto) {
    return this.contactService.create(dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete contact message' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.contactService.delete(id);
  }
}
