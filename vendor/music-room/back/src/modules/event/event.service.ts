import {
  Injectable,
  NotFoundException,
  ForbiddenException,
  ConflictException,
  BadRequestException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import {
  Event,
  EventVisibility,
  EventLicenseType,
  EventStatus,
} from './schemas/event.schema';
import { CreateEventDto, UpdateEventDto, SuggestTrackDto, VoteLocationDto } from './dto';

@Injectable()
export class EventService {
  constructor(
    @InjectModel(Event.name) private readonly eventModel: Model<Event>,
  ) {}

  // ─── Create Event ────────────────────────────────────

  async create(userId: string, dto: CreateEventDto): Promise<Event> {
    const event = await this.eventModel.create({
      ...dto,
      createdBy: new Types.ObjectId(userId),
      location: dto.location
        ? { type: 'Point', coordinates: dto.location.coordinates }
        : undefined,
      invitedUsers: dto.invitedUsers?.map((id) => new Types.ObjectId(id)) || [],
    });
    return event;
  }

  // ─── List Events ─────────────────────────────────────

  async findAll(userId: string, lat?: number, lng?: number): Promise<Event[]> {
    const query: any = {
      status: EventStatus.ACTIVE,
      $or: [
        { visibility: EventVisibility.PUBLIC },
        { createdBy: userId },
        { invitedUsers: userId },
      ],
    };

    // If location provided, sort by proximity
    if (lat !== undefined && lng !== undefined) {
      return this.eventModel
        .find(query)
        .sort({ 'location.coordinates': 1 })
        .limit(50)
        .populate('createdBy', 'publicInfo');
    }

    return this.eventModel
      .find(query)
      .sort({ createdAt: -1 })
      .limit(50)
      .populate('createdBy', 'publicInfo');
  }

  // ─── Get Event ───────────────────────────────────────

  async findOne(userId: string, eventId: string): Promise<Event> {
    const event = await this.eventModel
      .findById(eventId)
      .populate('createdBy', 'publicInfo')
      .populate('playlist.suggestedBy', 'publicInfo');

    if (!event) throw new NotFoundException('Event not found');

    // Check visibility access
    if (event.visibility === EventVisibility.PRIVATE) {
      const isOwner = event.createdBy._id.toString() === userId;
      const isInvited = event.invitedUsers.some((id) => id.toString() === userId);
      if (!isOwner && !isInvited) {
        throw new ForbiddenException('You do not have access to this event');
      }
    }

    return event;
  }

  // ─── Update Event ────────────────────────────────────

  async update(userId: string, eventId: string, dto: UpdateEventDto): Promise<Event> {
    const event = await this.eventModel.findById(eventId);
    if (!event) throw new NotFoundException('Event not found');
    if (event.createdBy.toString() !== userId) {
      throw new ForbiddenException('Only the event creator can update it');
    }

    const updateData: any = { ...dto };
    if (dto.location) {
      updateData.location = { type: 'Point', coordinates: dto.location.coordinates };
    }

    const updated = await this.eventModel.findByIdAndUpdate(eventId, updateData, { new: true });
    if (!updated) throw new NotFoundException('Event not found');
    return updated;
  }

  // ─── Delete Event ────────────────────────────────────

  async remove(userId: string, eventId: string): Promise<{ message: string }> {
    const event = await this.eventModel.findById(eventId);
    if (!event) throw new NotFoundException('Event not found');
    if (event.createdBy.toString() !== userId) {
      throw new ForbiddenException('Only the event creator can delete it');
    }

    await this.eventModel.findByIdAndDelete(eventId);
    return { message: 'Event deleted successfully' };
  }

  // ─── Invite Users ────────────────────────────────────

  async inviteUsers(userId: string, eventId: string, userIds: string[]): Promise<Event> {
    const event = await this.eventModel.findById(eventId);
    if (!event) throw new NotFoundException('Event not found');
    if (event.createdBy.toString() !== userId) {
      throw new ForbiddenException('Only the event creator can invite users');
    }

    const objectIds = userIds.map((id) => new Types.ObjectId(id));
    const updated = await this.eventModel.findByIdAndUpdate(
      eventId,
      { $addToSet: { invitedUsers: { $each: objectIds } } },
      { new: true },
    );
    if (!updated) throw new NotFoundException('Event not found');
    return updated;
  }

  // ─── Suggest Track ───────────────────────────────────

  async suggestTrack(userId: string, eventId: string, dto: SuggestTrackDto): Promise<Event> {
    const event = await this.eventModel.findById(eventId);
    if (!event) throw new NotFoundException('Event not found');

    // Check access
    this.checkEventAccess(event, userId);

    // Check if track already in playlist
    const exists = event.playlist.some(
      (t) => t.deezerTrackId === dto.deezerTrackId,
    );
    if (exists) {
      throw new ConflictException('Track already in the playlist');
    }

    // Use atomic update to avoid race conditions
    const updated = await this.eventModel.findByIdAndUpdate(
      eventId,
      {
        $push: {
          playlist: {
            deezerTrackId: dto.deezerTrackId,
            title: dto.title,
            artist: dto.artist,
            albumCover: dto.albumCover,
            previewUrl: dto.previewUrl,
            suggestedBy: new Types.ObjectId(userId),
            voteCount: 1,
            votedBy: [new Types.ObjectId(userId)], // Auto-vote when suggesting
          },
        },
      },
      { new: true },
    );

    return updated!;
  }

  // ─── Vote for Track ──────────────────────────────────

  async voteForTrack(
    userId: string,
    eventId: string,
    deezerTrackId: number,
    locationDto?: VoteLocationDto,
  ): Promise<Event> {
    const event = await this.eventModel.findById(eventId);
    if (!event) throw new NotFoundException('Event not found');

    // Check access and license
    this.checkVotePermission(event, userId, locationDto);

    const trackIndex = event.playlist.findIndex(
      (t) => t.deezerTrackId === deezerTrackId,
    );
    if (trackIndex === -1) {
      throw new NotFoundException('Track not found in event playlist');
    }

    // Check if user already voted — use atomic $addToSet to prevent race conditions
    const userObjectId = new Types.ObjectId(userId);
    const result = await this.eventModel.updateOne(
      {
        _id: eventId,
        'playlist.deezerTrackId': deezerTrackId,
        'playlist.votedBy': { $ne: userObjectId },
      },
      {
        $addToSet: { 'playlist.$.votedBy': userObjectId },
        $inc: { 'playlist.$.voteCount': 1 },
      },
    );

    if (result.modifiedCount === 0) {
      throw new ConflictException('You have already voted for this track');
    }

    // Return updated event with sorted playlist (highest votes first)
    const updated = await this.eventModel.findById(eventId);
    if (updated) {
      updated.playlist.sort((a, b) => b.voteCount - a.voteCount);
      await updated.save();
    }
    return updated!;
  }

  // ─── Remove Vote ─────────────────────────────────────

  async removeVote(userId: string, eventId: string, deezerTrackId: number): Promise<Event> {
    const event = await this.eventModel.findById(eventId);
    if (!event) throw new NotFoundException('Event not found');

    const userObjectId = new Types.ObjectId(userId);
    const result = await this.eventModel.updateOne(
      {
        _id: eventId,
        'playlist.deezerTrackId': deezerTrackId,
        'playlist.votedBy': userObjectId,
      },
      {
        $pull: { 'playlist.$.votedBy': userObjectId },
        $inc: { 'playlist.$.voteCount': -1 },
      },
    );

    if (result.modifiedCount === 0) {
      throw new NotFoundException('Vote not found');
    }

    const updated = await this.eventModel.findById(eventId);
    if (updated) {
      updated.playlist.sort((a, b) => b.voteCount - a.voteCount);
      await updated.save();
    }
    return updated!;
  }

  // ─── Access & License Checks (Private) ───────────────

  private checkEventAccess(event: Event, userId: string): void {
    if (event.visibility === EventVisibility.PRIVATE) {
      const isOwner = event.createdBy.toString() === userId;
      const isInvited = event.invitedUsers.some((id) => id.toString() === userId);
      if (!isOwner && !isInvited) {
        throw new ForbiddenException('You do not have access to this event');
      }
    }
  }

  private checkVotePermission(
    event: Event,
    userId: string,
    locationDto?: VoteLocationDto,
  ): void {
    // First check event access (public/private)
    this.checkEventAccess(event, userId);

    // Then check license type
    switch (event.licenseType) {
      case EventLicenseType.OPEN:
        // Anyone with event access can vote
        return;

      case EventLicenseType.INVITED_ONLY: {
        const isOwner = event.createdBy.toString() === userId;
        const isInvited = event.invitedUsers.some((id) => id.toString() === userId);
        if (!isOwner && !isInvited) {
          throw new ForbiddenException('Only invited users can vote in this event');
        }
        return;
      }

      case EventLicenseType.GEO_TIME: {
        // Check time window
        const now = new Date();
        if (event.timeWindow?.start && now < new Date(event.timeWindow.start)) {
          throw new ForbiddenException('Voting has not started yet');
        }
        if (event.timeWindow?.end && now > new Date(event.timeWindow.end)) {
          throw new ForbiddenException('Voting has ended');
        }

        // Check location
        if (!locationDto?.latitude || !locationDto?.longitude) {
          throw new BadRequestException('Location is required for geo-time licensed events');
        }

        const distance = this.haversineDistance(
          locationDto.latitude,
          locationDto.longitude,
          event.location.coordinates[1], // lat
          event.location.coordinates[0], // lng
        );

        if (distance > event.geoRadius) {
          throw new ForbiddenException(
            `You must be within ${event.geoRadius}m of the event to vote (you are ${Math.round(distance)}m away)`,
          );
        }
        return;
      }
    }
  }

  // Haversine formula to calculate distance between two GPS coordinates in meters
  private haversineDistance(
    lat1: number,
    lon1: number,
    lat2: number,
    lon2: number,
  ): number {
    const R = 6371000; // Earth radius in meters
    const dLat = this.toRad(lat2 - lat1);
    const dLon = this.toRad(lon2 - lon1);
    const a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(this.toRad(lat1)) *
        Math.cos(this.toRad(lat2)) *
        Math.sin(dLon / 2) *
        Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }

  private toRad(deg: number): number {
    return (deg * Math.PI) / 180;
  }
}
