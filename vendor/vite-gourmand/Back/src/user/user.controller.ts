/**
 * User Controller
 * User profile and management endpoints
 */
import {
  Controller,
  Get,
  Put,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { UserService } from './user.service';
import { AddressService } from './address.service';
import {
  CurrentUser,
  Roles,
  JwtPayload,
  PaginationDto,
  SafeParseIntPipe,
} from '../common';
import { UpdateProfileDto } from './dto/update-profile.dto';
import { UpdateAddressDto } from './dto/address.dto';

@ApiTags('users')
@Controller('users')
@ApiBearerAuth()
export class UserController {
  constructor(
    private readonly userService: UserService,
    private readonly addressService: AddressService,
  ) {}

  @Get('me')
  @ApiOperation({ summary: 'Get current user profile' })
  async getProfile(@CurrentUser() user: JwtPayload) {
    return this.userService.findById(user.sub);
  }

  @Put('me')
  @ApiOperation({ summary: 'Update current user profile' })
  async updateProfile(
    @CurrentUser() user: JwtPayload,
    @Body() dto: UpdateProfileDto,
  ) {
    return this.userService.update(user.sub, dto);
  }

  @Delete('me')
  @ApiOperation({ summary: 'Delete current user account' })
  async deleteAccount(@CurrentUser() user: JwtPayload) {
    return this.userService.softDelete(user.sub);
  }

  // Address management
  @Get('me/addresses')
  @ApiOperation({ summary: 'Get user addresses' })
  async getAddresses(@CurrentUser() user: JwtPayload) {
    return this.addressService.findByUser(user.sub);
  }

  @Put('me/addresses/:id')
  @ApiOperation({ summary: 'Update address' })
  async updateAddress(
    @CurrentUser() user: JwtPayload,
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateAddressDto,
  ) {
    return this.addressService.update(user.sub, id, dto);
  }

  // Admin endpoints
  @Get()
  @Roles('admin', 'manager')
  @ApiOperation({ summary: 'List all users (admin)' })
  async listUsers(@Query() pagination: PaginationDto) {
    return this.userService.findAll(pagination);
  }

  @Get(':id')
  @Roles('admin', 'manager')
  @ApiOperation({ summary: 'Get user by ID (admin)' })
  async getUserById(@Param('id', SafeParseIntPipe) id: number) {
    return this.userService.findById(id);
  }
}
