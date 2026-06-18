import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';

export type DelegationDocument = Delegation & Document;

export enum DelegationPermission {
  PLAYBACK_CONTROL = 'playback_control',
  PLAYLIST_EDIT = 'playlist_edit',
  VOLUME_CONTROL = 'volume_control',
  QUEUE_MANAGE = 'queue_manage',
}

export enum DelegationStatus {
  PENDING = 'pending',
  ACTIVE = 'active',
  REVOKED = 'revoked',
  EXPIRED = 'expired',
}

@Schema({ timestamps: true })
export class Delegation {
  @Prop({ type: Types.ObjectId, ref: 'User', required: true, index: true })
  granter: Types.ObjectId;

  @Prop({ type: Types.ObjectId, ref: 'User', required: true, index: true })
  delegate: Types.ObjectId;

  @Prop({ type: Types.ObjectId, ref: 'Device' })
  targetDevice?: Types.ObjectId;

  @Prop({
    type: [String],
    enum: Object.values(DelegationPermission),
    required: true,
  })
  permissions: DelegationPermission[];

  @Prop({
    type: String,
    enum: Object.values(DelegationStatus),
    default: DelegationStatus.PENDING,
  })
  status: DelegationStatus;

  @Prop()
  expiresAt?: Date;

  @Prop()
  revokedAt?: Date;
}

export const DelegationSchema = SchemaFactory.createForClass(Delegation);

// Compound index for quick look-up
DelegationSchema.index({ granter: 1, delegate: 1, status: 1 });
