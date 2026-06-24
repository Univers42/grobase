import {
  Controller,
  Get,
  Patch,
  Post,
  Delete,
  Param,
  Body,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse, ApiBearerAuth } from '@nestjs/swagger';
import { UserService } from './user.service';
import {
  UpdatePublicInfoDto,
  UpdateFriendsInfoDto,
  UpdatePrivateInfoDto,
  UpdateMusicPreferencesDto,
} from './dto';
import { CurrentUser } from '../../common/decorators/current-user.decorator';

@ApiTags('users')
@ApiBearerAuth()
@Controller('users')
export class UserController {
  constructor(private readonly userService: UserService) {}

  // ─── Own Profile ─────────────────────────────────────

  @Get('me')
  @ApiOperation({ summary: 'Get authenticated user profile' })
  @ApiResponse({ status: 200, description: 'Returns full user profile' })
  async getMyProfile(@CurrentUser('_id') userId: string) {
    return this.userService.getMyProfile(userId);
  }

  @Patch('me/public-info')
  @ApiOperation({ summary: 'Update public information' })
  @ApiResponse({ status: 200, description: 'Public info updated' })
  async updatePublicInfo(
    @CurrentUser('_id') userId: string,
    @Body() dto: UpdatePublicInfoDto,
  ) {
    return this.userService.updatePublicInfo(userId, dto);
  }

  @Patch('me/friends-info')
  @ApiOperation({ summary: 'Update friends-only information' })
  @ApiResponse({ status: 200, description: 'Friends info updated' })
  async updateFriendsInfo(
    @CurrentUser('_id') userId: string,
    @Body() dto: UpdateFriendsInfoDto,
  ) {
    return this.userService.updateFriendsInfo(userId, dto);
  }

  @Patch('me/private-info')
  @ApiOperation({ summary: 'Update private information' })
  @ApiResponse({ status: 200, description: 'Private info updated' })
  async updatePrivateInfo(
    @CurrentUser('_id') userId: string,
    @Body() dto: UpdatePrivateInfoDto,
  ) {
    return this.userService.updatePrivateInfo(userId, dto);
  }

  @Patch('me/music-preferences')
  @ApiOperation({ summary: 'Update music preferences' })
  @ApiResponse({ status: 200, description: 'Music preferences updated' })
  async updateMusicPreferences(
    @CurrentUser('_id') userId: string,
    @Body() dto: UpdateMusicPreferencesDto,
  ) {
    return this.userService.updateMusicPreferences(userId, dto);
  }

  // ─── Other User's Profile ───────────────────────────

  @Get(':id/profile')
  @ApiOperation({ summary: 'Get user profile (privacy-aware)' })
  @ApiResponse({ status: 200, description: 'Returns profile based on relationship' })
  @ApiResponse({ status: 404, description: 'User not found' })
  async getUserProfile(
    @CurrentUser('_id') requesterId: string,
    @Param('id') targetId: string,
  ) {
    return this.userService.getUserProfile(requesterId, targetId);
  }

  // ─── Friend System ───────────────────────────────────

  @Post(':id/friend-request')
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({ summary: 'Send a friend request' })
  @ApiResponse({ status: 201, description: 'Friend request sent' })
  @ApiResponse({ status: 409, description: 'Request already exists or already friends' })
  async sendFriendRequest(
    @CurrentUser('_id') userId: string,
    @Param('id') recipientId: string,
  ) {
    return this.userService.sendFriendRequest(userId, recipientId);
  }

  @Post(':id/friend-accept')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Accept a friend request' })
  @ApiResponse({ status: 200, description: 'Friend request accepted' })
  @ApiResponse({ status: 404, description: 'No pending request from this user' })
  async acceptFriendRequest(
    @CurrentUser('_id') userId: string,
    @Param('id') requesterId: string,
  ) {
    return this.userService.acceptFriendRequest(userId, requesterId);
  }

  @Delete(':id/friend')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Remove a friend' })
  @ApiResponse({ status: 200, description: 'Friend removed' })
  @ApiResponse({ status: 404, description: 'Friendship not found' })
  async removeFriend(
    @CurrentUser('_id') userId: string,
    @Param('id') friendId: string,
  ) {
    return this.userService.removeFriend(userId, friendId);
  }

  @Get('friends')
  @ApiOperation({ summary: 'List all friends' })
  @ApiResponse({ status: 200, description: 'Returns list of friends' })
  async getFriends(@CurrentUser('_id') userId: string) {
    return this.userService.getFriends(userId);
  }

  @Get('friends/pending')
  @ApiOperation({ summary: 'List pending friend requests' })
  @ApiResponse({ status: 200, description: 'Returns pending incoming requests' })
  async getPendingRequests(@CurrentUser('_id') userId: string) {
    return this.userService.getPendingRequests(userId);
  }
}
