import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document, Types } from 'mongoose';

export type RequestLogDocument = RequestLog & Document;

@Schema({ timestamps: true })
export class RequestLog {
  @Prop({ required: true })
  method: string;

  @Prop({ required: true })
  url: string;

  @Prop()
  statusCode: number;

  @Prop()
  responseTime: number; // ms

  @Prop({ type: Types.ObjectId, ref: 'User' })
  userId?: Types.ObjectId;

  @Prop()
  ip?: string;

  @Prop()
  userAgent?: string;

  @Prop()
  platform?: string; // ios | android | web | iot

  @Prop()
  deviceModel?: string;

  @Prop()
  appVersion?: string;

  @Prop({ type: Object })
  errorDetails?: Record<string, any>;
}

export const RequestLogSchema = SchemaFactory.createForClass(RequestLog);

// TTL index — auto-delete logs after 90 days
RequestLogSchema.index({ createdAt: 1 }, { expireAfterSeconds: 90 * 24 * 60 * 60 });
// Compound indexes for analytics
RequestLogSchema.index({ userId: 1, createdAt: -1 });
RequestLogSchema.index({ platform: 1, createdAt: -1 });
RequestLogSchema.index({ statusCode: 1, createdAt: -1 });
