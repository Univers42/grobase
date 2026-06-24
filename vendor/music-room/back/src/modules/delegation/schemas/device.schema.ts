import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';

export type DeviceDocument = Device & Document;

@Schema({ timestamps: true })
export class Device {
  @Prop({ type: Types.ObjectId, ref: 'User', required: true, index: true })
  owner: Types.ObjectId;

  @Prop({ required: true })
  name: string;

  @Prop({ required: true })
  platform: string; // ios | android | web | iot

  @Prop()
  deviceToken?: string; // Push-notification token

  @Prop()
  model?: string;

  @Prop()
  osVersion?: string;

  @Prop({ default: true })
  isActive: boolean;

  @Prop()
  lastSeenAt?: Date;
}

export const DeviceSchema = SchemaFactory.createForClass(Device);
