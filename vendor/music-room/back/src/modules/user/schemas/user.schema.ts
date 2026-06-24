import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';
import { ApiProperty } from '@nestjs/swagger';

// ─── Sub-documents ──────────────────────────────────────

@Schema({ _id: false })
export class PublicInfo {
  @ApiProperty({ example: 'John Doe' })
  @Prop({ default: '' })
  displayName: string;

  @ApiProperty({ example: 'https://example.com/avatar.png' })
  @Prop({ default: '' })
  avatar: string;

  @ApiProperty({ example: 'Music lover and DJ' })
  @Prop({ default: '' })
  bio: string;
}

@Schema({ _id: false })
export class FriendsInfo {
  @ApiProperty({ example: '+33612345678' })
  @Prop({ default: '' })
  phone: string;

  @ApiProperty({ example: 'Paris' })
  @Prop({ default: '' })
  city: string;

  @ApiProperty({ example: 25 })
  @Prop()
  age?: number;
}

@Schema({ _id: false })
export class PrivateInfo {
  @ApiProperty({ example: true })
  @Prop({ default: true })
  emailNotifications: boolean;

  @ApiProperty({ example: 'Some personal notes' })
  @Prop({ default: '' })
  personalNotes: string;
}

@Schema({ _id: false })
export class MusicPreferences {
  @ApiProperty({ example: ['rock', 'jazz', 'electronic'] })
  @Prop({ type: [String], default: [] })
  favoriteGenres: string[];

  @ApiProperty({ example: ['Daft Punk', 'Miles Davis'] })
  @Prop({ type: [String], default: [] })
  favoriteArtists: string[];

  @ApiProperty({ example: ['chill', 'energetic'] })
  @Prop({ type: [String], default: [] })
  preferredMoods: string[];
}

// ─── Main User Schema ───────────────────────────────────

@Schema({ timestamps: true })
export class User extends Document {
  @ApiProperty({ example: 'user@example.com' })
  @Prop({ required: true, unique: true, lowercase: true, trim: true })
  email: string;

  @Prop()
  passwordHash?: string;

  @ApiProperty({ example: false })
  @Prop({ default: false })
  isEmailVerified: boolean;

  @Prop()
  emailVerificationToken?: string;

  @Prop()
  emailVerificationExpires?: Date;

  @Prop()
  passwordResetToken?: string;

  @Prop()
  passwordResetExpires?: Date;

  // Social auth
  @Prop()
  googleId?: string;

  @Prop()
  facebookId?: string;

  @Prop({ type: [String], default: [] })
  linkedAccounts: string[]; // ['google', 'facebook']

  // Profile sections with privacy
  @Prop({ type: PublicInfo, default: () => ({}) })
  publicInfo: PublicInfo;

  @Prop({ type: FriendsInfo, default: () => ({}) })
  friendsInfo: FriendsInfo;

  @Prop({ type: PrivateInfo, default: () => ({}) })
  privateInfo: PrivateInfo;

  @Prop({ type: MusicPreferences, default: () => ({}) })
  musicPreferences: MusicPreferences;

  // Refresh token (hashed)
  @Prop()
  refreshTokenHash?: string;

  // Timestamps added by { timestamps: true }
  createdAt: Date;
  updatedAt: Date;
}

export const UserSchema = SchemaFactory.createForClass(User);

// Indexes
UserSchema.index({ email: 1 }, { unique: true });
UserSchema.index({ googleId: 1 }, { sparse: true });
UserSchema.index({ facebookId: 1 }, { sparse: true });
