import {
  Injectable,
  NotFoundException,
  ForbiddenException,
  ConflictException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import {
  Playlist,
  PlaylistVisibility,
  PlaylistLicenseType,
} from './schemas/playlist.schema';
import {
  CreatePlaylistDto,
  UpdatePlaylistDto,
  AddTrackDto,
  ReorderTrackDto,
} from './dto';

@Injectable()
export class PlaylistService {
  constructor(
    @InjectModel(Playlist.name) private readonly playlistModel: Model<Playlist>,
  ) {}

  // ─── Create Playlist ─────────────────────────────────

  async create(userId: string, dto: CreatePlaylistDto): Promise<Playlist> {
    return this.playlistModel.create({
      ...dto,
      createdBy: new Types.ObjectId(userId),
      collaborators: [new Types.ObjectId(userId)],
      invitedUsers: dto.invitedUsers?.map((id) => new Types.ObjectId(id)) || [],
    });
  }

  // ─── List Playlists ──────────────────────────────────

  async findAll(userId: string): Promise<Playlist[]> {
    return this.playlistModel
      .find({
        $or: [
          { visibility: PlaylistVisibility.PUBLIC },
          { createdBy: userId },
          { collaborators: userId },
          { invitedUsers: userId },
        ],
      })
      .sort({ updatedAt: -1 })
      .limit(50)
      .populate('createdBy', 'publicInfo')
      .select('-operationLog');
  }

  // ─── Get Playlist ────────────────────────────────────

  async findOne(userId: string, playlistId: string): Promise<Playlist> {
    const playlist = await this.playlistModel
      .findById(playlistId)
      .populate('createdBy', 'publicInfo')
      .populate('tracks.addedBy', 'publicInfo')
      .populate('collaborators', 'publicInfo');

    if (!playlist) throw new NotFoundException('Playlist not found');

    this.checkReadAccess(playlist, userId);
    return playlist;
  }

  // ─── Update Playlist ─────────────────────────────────

  async update(userId: string, playlistId: string, dto: UpdatePlaylistDto): Promise<Playlist> {
    const playlist = await this.playlistModel.findById(playlistId);
    if (!playlist) throw new NotFoundException('Playlist not found');
    if (playlist.createdBy.toString() !== userId) {
      throw new ForbiddenException('Only the playlist creator can update metadata');
    }

    const updated = await this.playlistModel.findByIdAndUpdate(playlistId, dto, { new: true });
    if (!updated) throw new NotFoundException('Playlist not found');
    return updated;
  }

  // ─── Delete Playlist ─────────────────────────────────

  async remove(userId: string, playlistId: string): Promise<{ message: string }> {
    const playlist = await this.playlistModel.findById(playlistId);
    if (!playlist) throw new NotFoundException('Playlist not found');
    if (playlist.createdBy.toString() !== userId) {
      throw new ForbiddenException('Only the playlist creator can delete it');
    }

    await this.playlistModel.findByIdAndDelete(playlistId);
    return { message: 'Playlist deleted successfully' };
  }

  // ─── Invite Collaborators ────────────────────────────

  async inviteCollaborators(userId: string, playlistId: string, userIds: string[]): Promise<Playlist> {
    const playlist = await this.playlistModel.findById(playlistId);
    if (!playlist) throw new NotFoundException('Playlist not found');
    if (playlist.createdBy.toString() !== userId) {
      throw new ForbiddenException('Only the playlist creator can invite collaborators');
    }

    const objectIds = userIds.map((id) => new Types.ObjectId(id));
    const updated = await this.playlistModel.findByIdAndUpdate(
      playlistId,
      {
        $addToSet: {
          invitedUsers: { $each: objectIds },
          collaborators: { $each: objectIds },
        },
      },
      { new: true },
    );
    if (!updated) throw new NotFoundException('Playlist not found');
    return updated;
  }

  // ─── Add Track (with OT versioning) ──────────────────

  async addTrack(userId: string, playlistId: string, dto: AddTrackDto): Promise<Playlist> {
    const playlist = await this.playlistModel.findById(playlistId);
    if (!playlist) throw new NotFoundException('Playlist not found');

    this.checkEditAccess(playlist, userId);
    this.checkVersion(playlist, dto.baseVersion);

    // Check duplicate
    const exists = playlist.tracks.some((t) => t.deezerTrackId === dto.deezerTrackId);
    if (exists) throw new ConflictException('Track already in playlist');

    const position = playlist.tracks.length;

    const updated = await this.playlistModel.findByIdAndUpdate(
      playlistId,
      {
        $push: {
          tracks: {
            deezerTrackId: dto.deezerTrackId,
            title: dto.title,
            artist: dto.artist,
            albumCover: dto.albumCover,
            previewUrl: dto.previewUrl,
            position,
            addedBy: new Types.ObjectId(userId),
          },
          operationLog: {
            type: 'add',
            deezerTrackId: dto.deezerTrackId,
            toPosition: position,
            performedBy: new Types.ObjectId(userId),
            baseVersion: dto.baseVersion,
            timestamp: new Date(),
          },
        },
        $inc: { version: 1 },
      },
      { new: true },
    );

    return updated!;
  }

  // ─── Remove Track (with OT versioning) ────────────────

  async removeTrack(userId: string, playlistId: string, deezerTrackId: number, baseVersion: number): Promise<Playlist> {
    const playlist = await this.playlistModel.findById(playlistId);
    if (!playlist) throw new NotFoundException('Playlist not found');

    this.checkEditAccess(playlist, userId);
    this.checkVersion(playlist, baseVersion);

    const trackIndex = playlist.tracks.findIndex((t) => t.deezerTrackId === deezerTrackId);
    if (trackIndex === -1) throw new NotFoundException('Track not found in playlist');

    // Remove track and reindex positions
    playlist.tracks.splice(trackIndex, 1);
    playlist.tracks.forEach((t, i) => (t.position = i));

    // Log operation
    playlist.operationLog.push({
      type: 'remove',
      deezerTrackId,
      fromPosition: trackIndex,
      performedBy: new Types.ObjectId(userId),
      baseVersion,
      timestamp: new Date(),
    } as any);

    playlist.version += 1;
    return playlist.save();
  }

  // ─── Reorder Track (with OT versioning) ───────────────

  async reorderTrack(userId: string, playlistId: string, dto: ReorderTrackDto): Promise<Playlist> {
    const playlist = await this.playlistModel.findById(playlistId);
    if (!playlist) throw new NotFoundException('Playlist not found');

    this.checkEditAccess(playlist, userId);
    this.checkVersion(playlist, dto.baseVersion);

    const trackIndex = playlist.tracks.findIndex(
      (t) => t.deezerTrackId === dto.deezerTrackId,
    );
    if (trackIndex === -1) throw new NotFoundException('Track not found in playlist');

    // Validate positions
    if (dto.fromPosition !== trackIndex) {
      // Position has changed since client's view — OT conflict
      throw new ConflictException(
        `Track position has changed. Expected position ${dto.fromPosition}, actual ${trackIndex}. Please refresh and retry.`,
      );
    }

    if (dto.toPosition < 0 || dto.toPosition >= playlist.tracks.length) {
      throw new ConflictException('Target position out of bounds');
    }

    // Move track
    const [track] = playlist.tracks.splice(trackIndex, 1);
    playlist.tracks.splice(dto.toPosition, 0, track);

    // Reindex all positions
    playlist.tracks.forEach((t, i) => (t.position = i));

    // Log operation
    playlist.operationLog.push({
      type: 'reorder',
      deezerTrackId: dto.deezerTrackId,
      fromPosition: dto.fromPosition,
      toPosition: dto.toPosition,
      performedBy: new Types.ObjectId(userId),
      baseVersion: dto.baseVersion,
      timestamp: new Date(),
    } as any);

    playlist.version += 1;
    return playlist.save();
  }

  // ─── Access Checks (Private) ─────────────────────────

  private checkReadAccess(playlist: Playlist, userId: string): void {
    if (playlist.visibility === PlaylistVisibility.PUBLIC) return;

    const isOwner = playlist.createdBy._id?.toString() === userId || playlist.createdBy.toString() === userId;
    const isCollaborator = playlist.collaborators.some((id) => id.toString() === userId);
    const isInvited = playlist.invitedUsers.some((id) => id.toString() === userId);

    if (!isOwner && !isCollaborator && !isInvited) {
      throw new ForbiddenException('You do not have access to this playlist');
    }
  }

  private checkEditAccess(playlist: Playlist, userId: string): void {
    // First check read access
    this.checkReadAccess(playlist, userId);

    if (playlist.licenseType === PlaylistLicenseType.INVITED_ONLY) {
      const isOwner = playlist.createdBy.toString() === userId;
      const isInvited = playlist.invitedUsers.some((id) => id.toString() === userId);
      if (!isOwner && !isInvited) {
        throw new ForbiddenException('Only invited users can edit this playlist');
      }
    }
  }

  private checkVersion(playlist: Playlist, baseVersion: number): void {
    if (baseVersion < playlist.version) {
      throw new ConflictException(
        `Version conflict: your version (${baseVersion}) is behind the current version (${playlist.version}). Please refresh and retry.`,
      );
    }
  }
}
