import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';
import { ApiProperty } from '@nestjs/swagger';

// ─── Enums ──────────────────────────────────────────────

export enum PlaylistVisibility {
  PUBLIC = 'public',
  PRIVATE = 'private',
}

export enum PlaylistLicenseType {
  OPEN = 'open',
  INVITED_ONLY = 'invited_only',
}

// ─── Sub-documents ──────────────────────────────────────

@Schema({ _id: false })
export class PlaylistTrackItem {
  @ApiProperty({ example: 123456 })
  @Prop({ required: true })
  deezerTrackId: number;

  @ApiProperty({ example: 'Get Lucky' })
  @Prop({ required: true })
  title: string;

  @ApiProperty({ example: 'Daft Punk' })
  @Prop({ required: true })
  artist: string;

  @ApiProperty({ example: 'https://...' })
  @Prop()
  albumCover?: string;

  @ApiProperty({ example: 'https://...' })
  @Prop()
  previewUrl?: string;

  @ApiProperty({ example: 0 })
  @Prop({ required: true })
  position: number;

  @Prop({ type: Types.ObjectId, ref: 'User' })
  addedBy: Types.ObjectId;
}

// ─── Operation Log (for OT) ────────────────────────────

@Schema({ _id: false })
export class PlaylistOperation {
  @Prop({ required: true })
  type: 'add' | 'remove' | 'reorder';

  @Prop()
  deezerTrackId?: number;

  @Prop()
  fromPosition?: number;

  @Prop()
  toPosition?: number;

  @Prop({ type: Types.ObjectId, ref: 'User' })
  performedBy: Types.ObjectId;

  @Prop({ required: true })
  baseVersion: number;

  @Prop({ default: () => new Date() })
  timestamp: Date;
}

// ─── Main Playlist Schema ───────────────────────────────

@Schema({ timestamps: true })
export class Playlist extends Document {
  @ApiProperty({ example: 'Chill Vibes' })
  @Prop({ required: true, trim: true })
  name: string;

  @ApiProperty({ example: 'A playlist for relaxing' })
  @Prop({ default: '' })
  description: string;

  @Prop({ type: Types.ObjectId, ref: 'User', required: true })
  createdBy: Types.ObjectId;

  @ApiProperty({ enum: PlaylistVisibility })
  @Prop({ type: String, enum: PlaylistVisibility, default: PlaylistVisibility.PUBLIC })
  visibility: PlaylistVisibility;

  @ApiProperty({ enum: PlaylistLicenseType })
  @Prop({ type: String, enum: PlaylistLicenseType, default: PlaylistLicenseType.OPEN })
  licenseType: PlaylistLicenseType;

  @Prop({ type: [Types.ObjectId], ref: 'User', default: [] })
  invitedUsers: Types.ObjectId[];

  @Prop({ type: [Types.ObjectId], ref: 'User', default: [] })
  collaborators: Types.ObjectId[];

  @Prop({ type: [PlaylistTrackItem], default: [] })
  tracks: PlaylistTrackItem[];

  @ApiProperty({ example: 1, description: 'Version counter for optimistic concurrency (OT)' })
  @Prop({ default: 0 })
  version: number;

  @Prop({ type: [PlaylistOperation], default: [] })
  operationLog: PlaylistOperation[];

  createdAt: Date;
  updatedAt: Date;
}

export const PlaylistSchema = SchemaFactory.createForClass(Playlist);

// Indexes
PlaylistSchema.index({ createdBy: 1 });
PlaylistSchema.index({ visibility: 1 });
PlaylistSchema.index({ collaborators: 1 });
