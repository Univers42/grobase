import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';

export type SubscriptionDocument = Subscription & Document;

export enum SubscriptionPlan {
  FREE = 'free',
  PREMIUM = 'premium',
}

export enum SubscriptionStatus {
  ACTIVE = 'active',
  CANCELLED = 'cancelled',
  EXPIRED = 'expired',
  PAST_DUE = 'past_due',
}

@Schema({ timestamps: true })
export class Subscription {
  @Prop({ type: Types.ObjectId, ref: 'User', required: true, unique: true })
  user: Types.ObjectId;

  @Prop({
    type: String,
    enum: Object.values(SubscriptionPlan),
    default: SubscriptionPlan.FREE,
  })
  plan: SubscriptionPlan;

  @Prop({
    type: String,
    enum: Object.values(SubscriptionStatus),
    default: SubscriptionStatus.ACTIVE,
  })
  status: SubscriptionStatus;

  @Prop()
  externalId?: string; // Stripe / payment provider ID

  @Prop()
  currentPeriodStart?: Date;

  @Prop()
  currentPeriodEnd?: Date;

  @Prop()
  cancelledAt?: Date;

  @Prop({ type: Object })
  features: {
    maxPlaylists: number;
    maxEventsPerMonth: number;
    maxCollaboratorsPerPlaylist: number;
    canExportPlaylist: boolean;
    adsEnabled: boolean;
    prioritySupport: boolean;
  };
}

export const SubscriptionSchema = SchemaFactory.createForClass(Subscription);

/** Default feature sets per plan */
export const PLAN_FEATURES: Record<SubscriptionPlan, Subscription['features']> = {
  [SubscriptionPlan.FREE]: {
    maxPlaylists: 5,
    maxEventsPerMonth: 3,
    maxCollaboratorsPerPlaylist: 5,
    canExportPlaylist: false,
    adsEnabled: true,
    prioritySupport: false,
  },
  [SubscriptionPlan.PREMIUM]: {
    maxPlaylists: -1, // unlimited
    maxEventsPerMonth: -1,
    maxCollaboratorsPerPlaylist: -1,
    canExportPlaylist: true,
    adsEnabled: false,
    prioritySupport: true,
  },
};
