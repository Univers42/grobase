import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';
import { ApiProperty } from '@nestjs/swagger';

// ─── Enums ──────────────────────────────────────────────

export enum EventVisibility {
  PUBLIC = 'public',
  PRIVATE = 'private',
}

export enum EventLicenseType {
  OPEN = 'open',
  INVITED_ONLY = 'invited_only',
  GEO_TIME = 'geo_time',
}

export enum EventStatus {
  ACTIVE = 'active',
  ENDED = 'ended',
}

// ─── Sub-documents ──────────────────────────────────────

@Schema({ _id: false })
export class EventLocation {
  @ApiProperty({ example: 'Point' })
  @Prop({ default: 'Point' })
  type: string;

  @ApiProperty({ example: [2.3522, 48.8566], description: '[longitude, latitude]' })
  @Prop({ type: [Number], default: [0, 0] })
  coordinates: number[];
}

@Schema({ _id: false })
export class TimeWindow {
  @ApiProperty({ example: '2026-03-18T16:00:00Z' })
  @Prop()
  start?: Date;

  @ApiProperty({ example: '2026-03-18T18:00:00Z' })
  @Prop()
  end?: Date;
}

@Schema({ _id: false })
export class PlaylistTrack {
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

  @Prop({ type: Types.ObjectId, ref: 'User' })
  suggestedBy: Types.ObjectId;

  @ApiProperty({ example: 5 })
  @Prop({ default: 0 })
  voteCount: number;

  @Prop({ type: [Types.ObjectId], ref: 'User', default: [] })
  votedBy: Types.ObjectId[];
}

// ─── Main Event Schema ──────────────────────────────────

@Schema({ timestamps: true })
export class Event extends Document {
  @ApiProperty({ example: 'Friday Night Party' })
  @Prop({ required: true, trim: true })
  name: string;

  @ApiProperty({ example: 'An awesome music event' })
  @Prop({ default: '' })
  description: string;

  @Prop({ type: Types.ObjectId, ref: 'User', required: true })
  createdBy: Types.ObjectId;

  @ApiProperty({ enum: EventVisibility })
  @Prop({ type: String, enum: EventVisibility, default: EventVisibility.PUBLIC })
  visibility: EventVisibility;

  @ApiProperty({ enum: EventLicenseType })
  @Prop({ type: String, enum: EventLicenseType, default: EventLicenseType.OPEN })
  licenseType: EventLicenseType;

  @Prop({ type: [Types.ObjectId], ref: 'User', default: [] })
  invitedUsers: Types.ObjectId[];

  @Prop({ type: EventLocation, default: () => ({}) })
  location: EventLocation;

  @ApiProperty({ example: 500, description: 'Radius in meters for geo-based license' })
  @Prop({ default: 500 })
  geoRadius: number;

  @Prop({ type: TimeWindow, default: () => ({}) })
  timeWindow: TimeWindow;

  @Prop({ type: [PlaylistTrack], default: [] })
  playlist: PlaylistTrack[];

  @Prop({ type: PlaylistTrack })
  nowPlaying?: PlaylistTrack;

  @ApiProperty({ enum: EventStatus })
  @Prop({ type: String, enum: EventStatus, default: EventStatus.ACTIVE })
  status: EventStatus;

  createdAt: Date;
  updatedAt: Date;
}

export const EventSchema = SchemaFactory.createForClass(Event);

// Indexes
EventSchema.index({ createdBy: 1 });
EventSchema.index({ visibility: 1, status: 1 });
EventSchema.index({ 'location.coordinates': '2dsphere' });
