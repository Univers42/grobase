import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';
import { ApiProperty } from '@nestjs/swagger';

export enum FriendStatus {
  PENDING = 'pending',
  ACCEPTED = 'accepted',
}

@Schema({ timestamps: true })
export class Friend extends Document {
  @ApiProperty({ description: 'User who sent the friend request' })
  @Prop({ type: Types.ObjectId, ref: 'User', required: true })
  requester: Types.ObjectId;

  @ApiProperty({ description: 'User who received the friend request' })
  @Prop({ type: Types.ObjectId, ref: 'User', required: true })
  recipient: Types.ObjectId;

  @ApiProperty({ enum: FriendStatus, example: FriendStatus.PENDING })
  @Prop({ type: String, enum: FriendStatus, default: FriendStatus.PENDING })
  status: FriendStatus;

  createdAt: Date;
  updatedAt: Date;
}

export const FriendSchema = SchemaFactory.createForClass(Friend);

// Indexes
FriendSchema.index({ requester: 1, recipient: 1 }, { unique: true });
FriendSchema.index({ recipient: 1, status: 1 });
