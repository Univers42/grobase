import {
  Controller,
  Post,
  Get,
  Patch,
  Delete,
  Param,
  Body,
  Query,
} from '@nestjs/common';
import {
  ApiTags,
  ApiBearerAuth,
  ApiOperation,
  ApiParam,
  ApiQuery,
} from '@nestjs/swagger';
import { PlaylistService } from './playlist.service';
import { PlaylistGateway } from './gateways';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import {
  CreatePlaylistDto,
  UpdatePlaylistDto,
  AddTrackDto,
  ReorderTrackDto,
  RemoveTrackDto,
  InviteCollaboratorsDto,
} from './dto';

@ApiTags('playlists')
@ApiBearerAuth()
@Controller('playlists')
export class PlaylistController {
  constructor(
    private readonly playlistService: PlaylistService,
    private readonly playlistGateway: PlaylistGateway,
  ) {}

  @Post()
  @ApiOperation({ summary: 'Create a new collaborative playlist' })
  async create(
    @CurrentUser() user: any,
    @Body() dto: CreatePlaylistDto,
  ) {
    return this.playlistService.create(user._id, dto);
  }

  @Get()
  @ApiOperation({ summary: 'List playlists accessible to current user' })
  @ApiQuery({ name: 'page', required: false, type: Number })
  @ApiQuery({ name: 'limit', required: false, type: Number })
  async findAll(
    @CurrentUser() user: any,
    @Query('page') page = 1,
    @Query('limit') limit = 20,
  ) {
    return this.playlistService.findAllAccessible(user._id, +page, +limit);
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get playlist by id' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  async findOne(
    @CurrentUser() user: any,
    @Param('id') id: string,
  ) {
    return this.playlistService.findById(id, user._id);
  }

  @Patch(':id')
  @ApiOperation({ summary: 'Update playlist metadata' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  async update(
    @CurrentUser() user: any,
    @Param('id') id: string,
    @Body() dto: UpdatePlaylistDto,
  ) {
    return this.playlistService.update(id, user._id, dto);
  }

  @Delete(':id')
  @ApiOperation({ summary: 'Delete playlist (owner only)' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  async remove(
    @CurrentUser() user: any,
    @Param('id') id: string,
  ) {
    return this.playlistService.delete(id, user._id);
  }

  @Post(':id/invite')
  @ApiOperation({ summary: 'Invite collaborators to the playlist' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  async invite(
    @CurrentUser() user: any,
    @Param('id') id: string,
    @Body() dto: InviteCollaboratorsDto,
  ) {
    return this.playlistService.inviteCollaborators(id, user._id, dto);
  }

  @Post(':id/tracks')
  @ApiOperation({ summary: 'Add a track to the playlist' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  async addTrack(
    @CurrentUser() user: any,
    @Param('id') id: string,
    @Body() dto: AddTrackDto,
  ) {
    const playlist = await this.playlistService.addTrack(id, user._id, dto);
    const addedTrack = playlist.tracks[playlist.tracks.length - 1];
    this.playlistGateway.emitTrackAdded(id, addedTrack, playlist.version);
    return playlist;
  }

  @Delete(':id/tracks/:deezerTrackId')
  @ApiOperation({ summary: 'Remove a track from the playlist' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  @ApiParam({ name: 'deezerTrackId', description: 'Deezer track ID' })
  @ApiQuery({ name: 'baseVersion', required: true, type: Number })
  async removeTrack(
    @CurrentUser() user: any,
    @Param('id') id: string,
    @Param('deezerTrackId') deezerTrackId: string,
    @Query('baseVersion') baseVersion: string,
  ) {
    const dto: RemoveTrackDto = {
      deezerTrackId: +deezerTrackId,
      baseVersion: +baseVersion,
    };
    const playlist = await this.playlistService.removeTrack(id, user._id, dto);
    this.playlistGateway.emitTrackRemoved(id, +deezerTrackId, playlist.version);
    return playlist;
  }

  @Patch(':id/tracks/reorder')
  @ApiOperation({ summary: 'Reorder a track in the playlist' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  async reorderTrack(
    @CurrentUser() user: any,
    @Param('id') id: string,
    @Body() dto: ReorderTrackDto,
  ) {
    const playlist = await this.playlistService.reorderTrack(id, user._id, dto);
    this.playlistGateway.emitTrackReordered(
      id,
      dto.deezerTrackId,
      dto.fromPosition,
      dto.toPosition,
      playlist.version,
    );
    return playlist;
  }

  @Get(':id/operations')
  @ApiOperation({ summary: 'Get operation history for the playlist' })
  @ApiParam({ name: 'id', description: 'Playlist ID' })
  async getOperations(
    @CurrentUser() user: any,
    @Param('id') id: string,
  ) {
    const playlist = await this.playlistService.findById(id, user._id);
    return { operations: playlist.operations, version: playlist.version };
  }
}
