/**
 * Message DTOs
 */
import {
  IsString,
  IsOptional,
  IsNumber,
  IsEnum,
  MaxLength,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export enum MessagePriority {
  LOW = 'low',
  NORMAL = 'normal',
  HIGH = 'high',
  URGENT = 'urgent',
}

export class CreateMessageDto {
  @ApiProperty({ example: 1 })
  @IsNumber()
  recipientId!: number;

  @ApiPropertyOptional({ example: 'Question about my order' })
  @IsOptional()
  @IsString()
  @MaxLength(255)
  subject?: string;

  @ApiProperty({ example: 'Hello, I have a question about...' })
  @IsString()
  body!: string;

  @ApiPropertyOptional({ enum: MessagePriority, example: 'normal' })
  @IsOptional()
  @IsEnum(MessagePriority)
  priority?: MessagePriority;

  @ApiPropertyOptional({
    example: 1,
    description: 'Parent message ID for replies',
  })
  @IsOptional()
  @IsNumber()
  parentId?: number;
}

export class ReplyMessageDto {
  @ApiProperty({ example: 'Thank you for your response...' })
  @IsString()
  body!: string;
}
