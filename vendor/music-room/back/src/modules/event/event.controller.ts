import {
  Controller,
  Get,
  Post,
  Patch,
  Delete,
  Param,
  Body,
  Query,
  HttpCode,
  HttpStatus,
  ParseIntPipe,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse, ApiBearerAuth, ApiQuery } from '@nestjs/swagger';
import { EventService } from './event.service';
import { VoteGateway } from './gateways/vote.gateway';
import {
  CreateEventDto,
  UpdateEventDto,
  SuggestTrackDto,
  InviteUsersDto,
  VoteLocationDto,
} from './dto';
import { CurrentUser } from '../../common/decorators/current-user.decorator';

@ApiTags('events')
@ApiBearerAuth()
@Controller('events')
export class EventController {
  constructor(
    private readonly eventService: EventService,
    private readonly voteGateway: VoteGateway,
  ) {}

  // ─── CRUD ────────────────────────────────────────────

  @Post()
  @ApiOperation({ summary: 'Create a new event' })
  @ApiResponse({ status: 201, description: 'Event created' })
  async create(
    @CurrentUser('_id') userId: string,
    @Body() dto: CreateEventDto,
  ) {
    return this.eventService.create(userId, dto);
  }

  @Get()
  @ApiOperation({ summary: 'List events (public + accessible private)' })
  @ApiQuery({ name: 'lat', required: false, description: 'Latitude for proximity sort' })
  @ApiQuery({ name: 'lng', required: false, description: 'Longitude for proximity sort' })
  @ApiResponse({ status: 200, description: 'Returns list of events' })
  async findAll(
    @CurrentUser('_id') userId: string,
    @Query('lat') lat?: number,
    @Query('lng') lng?: number,
  ) {
    return this.eventService.findAll(userId, lat, lng);
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get event details' })
  @ApiResponse({ status: 200, description: 'Returns event' })
  @ApiResponse({ status: 403, description: 'No access to private event' })
  @ApiResponse({ status: 404, description: 'Event not found' })
  async findOne(
    @CurrentUser('_id') userId: string,
    @Param('id') eventId: string,
  ) {
    return this.eventService.findOne(userId, eventId);
  }

  @Patch(':id')
  @ApiOperation({ summary: 'Update event (creator only)' })
  @ApiResponse({ status: 200, description: 'Event updated' })
  async update(
    @CurrentUser('_id') userId: string,
    @Param('id') eventId: string,
    @Body() dto: UpdateEventDto,
  ) {
    return this.eventService.update(userId, eventId, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Delete event (creator only)' })
  @ApiResponse({ status: 200, description: 'Event deleted' })
  async remove(
    @CurrentUser('_id') userId: string,
    @Param('id') eventId: string,
  ) {
    return this.eventService.remove(userId, eventId);
  }

  // ─── Invitations ─────────────────────────────────────

  @Post(':id/invite')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Invite users to event' })
  @ApiResponse({ status: 200, description: 'Users invited' })
  async inviteUsers(
    @CurrentUser('_id') userId: string,
    @Param('id') eventId: string,
    @Body() dto: InviteUsersDto,
  ) {
    return this.eventService.inviteUsers(userId, eventId, dto.userIds);
  }

  // ─── Track Suggestion ────────────────────────────────

  @Post(':id/suggest')
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({ summary: 'Suggest a track for the event playlist' })
  @ApiResponse({ status: 201, description: 'Track suggested and auto-voted' })
  @ApiResponse({ status: 409, description: 'Track already in playlist' })
  async suggestTrack(
    @CurrentUser('_id') userId: string,
    @Param('id') eventId: string,
    @Body() dto: SuggestTrackDto,
  ) {
    const event = await this.eventService.suggestTrack(userId, eventId, dto);
    // Emit real-time update
    this.voteGateway.emitPlaylistUpdated(eventId, event.playlist);
    return event;
  }

  // ─── Voting ──────────────────────────────────────────

  @Post(':id/vote/:trackId')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Vote for a track in the event' })
  @ApiResponse({ status: 200, description: 'Vote registered' })
  @ApiResponse({ status: 409, description: 'Already voted for this track' })
  async voteForTrack(
    @CurrentUser('_id') userId: string,
    @Param('id') eventId: string,
    @Param('trackId', ParseIntPipe) trackId: number,
    @Body() locationDto: VoteLocationDto,
  ) {
    const event = await this.eventService.voteForTrack(userId, eventId, trackId, locationDto);
    // Emit real-time updates
    const track = event.playlist.find((t) => t.deezerTrackId === trackId);
    if (track) {
      this.voteGateway.emitVoteReceived(eventId, trackId, track.voteCount);
    }
    this.voteGateway.emitPlaylistUpdated(eventId, event.playlist);
    return event;
  }

  @Delete(':id/vote/:trackId')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Remove vote for a track' })
  @ApiResponse({ status: 200, description: 'Vote removed' })
  async removeVote(
    @CurrentUser('_id') userId: string,
    @Param('id') eventId: string,
    @Param('trackId', ParseIntPipe) trackId: number,
  ) {
    const event = await this.eventService.removeVote(userId, eventId, trackId);
    this.voteGateway.emitPlaylistUpdated(eventId, event.playlist);
    return event;
  }
}
